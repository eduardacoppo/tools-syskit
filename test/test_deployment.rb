require 'syskit'
require 'syskit/test'

describe Syskit::TaskContext do
    include Syskit::SelfTest

    attr_reader :deployment_task, :task_m, :orogen_deployed_task, :deployment_m
    before do
        @task_m = Syskit::TaskContext.new_submodel
        orogen_model = Orocos::Spec::Deployment.new(Orocos.master_project, 'deployment')
        @orogen_deployed_task = orogen_model.task 'task', task_m.orogen_model
        @deployment_m = Syskit::Deployment.new_submodel(:orogen_model => orogen_model)
        plan.add(@deployment_task = deployment_m.new)
    end

    describe "#pid" do
        it "returns nil when not running" do
            task = Syskit::Deployment.new_submodel.new
            assert !task.pid
        end
        it "returns orocos_process.pid otherwise" do
            task = Syskit::Deployment.new_submodel.new
            flexmock(task).should_receive(:running?).and_return(true)
            flexmock(task).should_receive(:orocos_process).and_return(flexmock(:pid => (pid = Object.new)))
            assert_same pid, task.pid
        end
    end

    describe "#task" do
        it "raises ArgumentError if the given activity name is not a task name for this deployment" do
            assert_raises(ArgumentError) { deployment_task.task "bla" }
        end
        it "returns a new task of the right syskit model" do
            assert_kind_of task_m, deployment_task.task("task")
        end
        it "can create a new task of a specified syskit model" do
            explicit_m = task_m.new_submodel
            assert_kind_of explicit_m, deployment_task.task("task", explicit_m)
        end
        it "raises ArgumentError if the explicit model does not fullfill the expected one" do
            explicit_m = Syskit::TaskContext.new_submodel
            assert_raises(ArgumentError) { deployment_task.task("task", explicit_m) }
        end
        it "sets orocos_name on the new task" do
            assert_equal 'task', deployment_task.task("task").orocos_name
        end
        it "sets orogen_model on the new task" do
            assert_equal orogen_deployed_task, deployment_task.task("task").orogen_model
        end
        it "adds the deployment task as an execution agent for the new task" do
            flexmock(task_m).new_instances.should_receive(:executed_by).with(deployment_task).once
            deployment_task.task("task")
        end
        it "does not do runtime initialization if it is not yet ready" do
            flexmock(deployment_task).should_receive(:initialize_running_task).never
            flexmock(deployment_task).should_receive(:ready?).and_return(false)
            deployment_task.task("task")
        end
        it "does runtime initialization if it is already ready" do
            task = task_m.new
            flexmock(task_m).should_receive(:new).and_return(task)
            flexmock(deployment_task).should_receive(:task_handles).and_return('task' => (orocos_task = Object.new))
            flexmock(deployment_task).should_receive(:initialize_running_task).with(task, orocos_task).once
            flexmock(deployment_task).should_receive(:ready?).and_return(true)
            deployment_task.task("task")
        end
    end

    describe "#initialize_running_task" do
        it "initializes orocos_task with the data known to the deployment" do
            orocos_task = flexmock
            flexmock(deployment_task).should_receive(:task_handles).and_return(Hash['bla' => orocos_task])
            orocos_task.should_receive(:log_all_configuration)

            task = task_m.new
            deployment_task.initialize_running_task(task, orocos_task)
            assert_equal orocos_task, task.orocos_task
        end
    end

    describe "#initialize" do
        it "sets the target host to localhost by default" do
            task = Syskit::Deployment.new
            assert_equal 'localhost', task.host
        end
    end

    describe "#host" do
        it "returns the name of the process server this deployment should be started on" do
            task = Syskit::Deployment.new(:on => 'bla')
            assert_equal 'bla', task.host
        end
    end

    describe "runtime behaviour" do
        attr_reader :process_server, :process, :log_dir
        before do
            @process_server = flexmock('process_server')
            process_server.should_receive(:disconnect).by_default
            @process = flexmock('process')
            process.should_receive(:kill).by_default
            process.should_receive(:wait_running).by_default
            @log_dir = flexmock('log_dir')
            Syskit.register_process_server('bla', process_server, log_dir)
            deployment_task.arguments[:on] = 'bla'
        end
        after do
            if deployment_task.running?
                deployment_task.dead!(nil)
            end
        end

        describe "start_event" do
            it "finds the process server from Syskit.process_servers and its 'on' option" do
                process_server.should_receive(:start).once.with('deployment', any).and_return(process)
                deployment_task.start!
            end
            it "passes the process server's log dir as working directory" do
                process_server.should_receive(:start).once.with(any, hsh(:working_directory => log_dir)).and_return(process)
                deployment_task.start!
            end
            it "passes the model-level run command line options to the process server start command" do
                cmdline_options = {:valgrind => true}
                deployment_m.default_run_options.merge!(cmdline_options)
                process_server.should_receive(:start).with(any, hsh(:cmdline_args => cmdline_options)).and_return(process)
                deployment_task.start!
            end
            it "raises if the on option refers to a non-existing process server" do
                deployment_task.arguments[:on] = 'bla'
                assert_raises(Roby::CommandFailed) { deployment_task.start! }
            end
            it "does not emit ready" do
                process_server.should_receive(:start).and_return(process)
                deployment_task.start!
                assert !deployment_task.ready?
            end
        end

        describe "poll block" do
            attr_reader :orocos_task
            before do
                process_server.should_receive(:start).and_return(process)
                process.should_receive(:wait_running).by_default
                process.should_receive(:get_mapped_name).
                    with('task').and_return('mapped_task_name')
                @orocos_task = flexmock
                orocos_task.should_receive(:rtt_state => :PRE_OPERATIONAL).
                    by_default
                orocos_task.should_receive(:process=).
                    with(process)
                flexmock(Orocos::TaskContext).should_receive(:get).with('mapped_task_name').and_return(orocos_task)
                deployment_task.start!
            end
            it "does not emit ready if the process is not ready yet" do
                process.should_receive(:wait_running).once.and_return(false)
                process_events
                assert !deployment_task.ready?
            end
            it "emits ready when the process is ready" do
                process.should_receive(:wait_running).once.and_return(true)
                process_events
                assert deployment_task.ready?
            end
            it "resolves all deployment tasks into task_handles using mapped names" do
                process.should_receive(:wait_running).once.and_return(true)
                process_events
                assert_equal orocos_task, deployment_task.task_handles['task']
            end
            it "initializes supported task contexts" do
                process.should_receive(:wait_running).once.and_return(true)
                task = Class.new(Roby::Task) do
                    argument :orocos_name
                    terminates
                end.new(:orocos_name => 'task')

                task.executed_by deployment_task
                flexmock(deployment_task).should_receive(:initialize_running_task).once.
                    with(task, orocos_task)
                process_events
            end
        end
        
        describe "stop event" do
            attr_reader :orocos_task
            before do
                process_server.should_receive(:start).and_return(process)
                process.should_receive(:wait_running).and_return(true)
                process.should_receive(:get_mapped_name).
                    with('task').and_return('mapped_task_name')
                @orocos_task = flexmock
                orocos_task.should_receive(:rtt_state).
                    and_return(:PRE_OPERATIONAL).by_default
                orocos_task.should_receive(:process=).
                    with(process)
                flexmock(Orocos::TaskContext).should_receive(:get).with('mapped_task_name').and_return(orocos_task)
                deployment_task.start!
            end
            it "cleans up all stopped tasks" do
                orocos_task.should_receive(:rtt_state).and_return(:STOPPED)
                orocos_task.should_receive(:cleanup).once
                deployment_task.stop!
            end
            it "marks the task as ready to die" do
                deployment_task.stop!
                assert deployment_task.ready_to_die?
            end
            it "does not emit stop" do
                deployment_task.stop!
                assert !deployment_task.finished?
            end
            it "kills the process" do
                process.should_receive(:kill).once
                deployment_task.stop!
            end
            it "ignores com errors with the tasks" do
                orocos_task.should_receive(:cleanup).and_raise(Orocos::ComError)
                deployment_task.stop!
            end
            it "emits stop if kill fails with a communication error" do
                process.should_receive(:kill).and_raise(Orocos::ComError)
                deployment_task.stop!
                assert deployment_task.failed?
            end
        end
    end
end


