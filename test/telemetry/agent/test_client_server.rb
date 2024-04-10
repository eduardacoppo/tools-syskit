# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/agent/server"
require "syskit/telemetry/agent/client"

module Syskit
    module Telemetry
        module Agent
            describe "Client and Server" do
                before do
                    @rpc = GRPC::RpcServer.new
                    @rpc_port = @rpc.add_http2_port("localhost:0", :this_port_is_insecure)

                    @name_service = Orocos::Local::NameService.new
                    @server = Server.new(@name_service)
                    @rpc.handle(@server)
                    @client =
                        Client.new("localhost:#{@rpc_port}", :this_channel_is_insecure)

                    @rpc_thread = Thread.new do
                        @rpc.run_till_terminated
                    end
                    @rpc.wait_till_running(10)
                end

                after do
                    @rpc.stop
                    @rpc_thread.join
                    Orocos.allow_blocking_calls { @server.dispose }
                end

                describe "with an established data channel" do
                    before do
                        @data_channel = DataChannel.setup(@client)
                    end

                    after do
                        @data_channel.dispose
                        @data_channel.join
                    end

                    it "sends port updates when a monitored port is updated" do
                        task = create_task_and_port("task", "out")
                        monitor_id, _disposable = @client.monitor_port(
                            "task", "out", period: 0.1, type: :buffer, size: 20
                        )

                        assert_client_receives(
                            { monitor_id => { type: task.out.type, values: [42] } }
                        ) do
                            task.out.write 42
                        end
                    end

                    it "stops monitoring a port when the monitor is disposed of" do
                        task = create_task_and_port("task", "out")
                        _monitor_id, disposable = @client.monitor_port(
                            "task", "out", period: 0.1, type: :buffer, size: 20
                        )
                        disposable.dispose

                        assert_client_receives_nothing do
                            task.out.write 42
                        end
                    end

                    def assert_client_receives(expected, timeout: 10)
                        @data_channel.clear

                        yield

                        until expected.empty?
                            sample = @data_channel.deq(timeout)
                            assert_client_received_expected(expected, sample)
                        end
                    end

                    def assert_client_receives_nothing(timeout: 1)
                        @data_channel.clear

                        yield

                        @data_channel.deq(timeout)
                        flunk("received sample on channel but none were expected")
                    rescue Syskit::Telemetry::Agent::QueueWithTimeout::WaitTimedOut
                        assert(true) # to count assertions
                    end
                end

                def create_task_and_port(task_name, port_name)
                    task = Orocos.allow_blocking_calls do
                        task = Orocos::RubyTasks::TaskContext.new(task_name)
                        task.create_output_port port_name, "/double"
                        task
                    end
                    @name_service.register(task)
                    @name_service.register(task, name: task_name)
                end

                class QueueWithTimeout
                    def initialize
                        @queue = []
                        @mu = Mutex.new
                        @cv = ConditionVariable.new
                    end

                    def enq(element)
                        @mu.synchronize do
                            @queue << element
                            @cv.signal
                        end
                    end

                    def deq(timeout)
                        @mu.synchronize do
                            wait_locked(timeout) if @queue.empty?
                            @queue.shift
                        end
                    end

                    def clear
                        @mu.synchronize { @queue.clear }
                    end

                    class WaitTimedOut < RuntimeError; end

                    def wait_locked(timeout)
                        deadline = Time.now + timeout

                        loop do
                            @cv.wait(@mu, timeout)

                            if @queue.empty?
                                next if Time.now < deadline

                                raise WaitTimedOut,
                                      "timed out waiting for queue to have elements"
                            end

                            return @queue.first
                        end
                    end
                end

                DataChannel = Struct.new :op, :queue, :thread, keyword_init: true do # rubocop:disable Metrics/BlockLength
                    def self.setup(client)
                        data_op = client.data(Grpc::Void.new, return_op: true)
                        sample_queue = QueueWithTimeout.new

                        channel_ready = Concurrent::Event.new
                        pull_thread = Thread.new do
                            enum = data_op.execute
                            channel_ready.set
                            enum.each do |sample|
                                sample_queue.enq(sample)
                            end
                        rescue GRPC::Core::CallError, GRPC::Cancelled # rubocop:disable Lint/SuppressedException
                        end
                        channel_ready.wait

                        new(op: data_op, queue: sample_queue, thread: pull_thread)
                    end

                    def clear
                        queue.clear
                    end

                    def dispose
                        cancel
                    end

                    def cancel
                        op.cancel
                    end

                    def join
                        thread.join
                    end

                    def deq(timeout)
                        queue.deq(timeout)
                    end
                end

                def assert_client_received_expected(expected, sample)
                    assert(id_expectations = expected[sample.id])
                    type = id_expectations[:type]

                    values = id_expectations[:values]
                    next_value = values.shift
                    assert_equal(next_value, type.from_buffer(sample.data))
                    expected.delete(sample.id) if values.empty?
                end
            end
        end
    end
end
