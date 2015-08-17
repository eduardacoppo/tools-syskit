require '<%= Roby::App.resolve_robot_in_path("models/#{subdir}/#{basename}") %>'
<% indent, open, close = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open %>
<%= indent %>describe <%= class_name.last %> do
<%= indent %>    it "starts" do
<%= indent %>        # Note, you might want to inject specific children
<%= indent %>        # here, but it is not strictly required. The syskit_stub_*
<%= indent %>        # methods generate what is needed to have a run-able composition
<%= indent %>        cmp_task = syskit_stub_deploy_configure_and_start(<%= class_name.last %>)

<%= indent %>        # At this point, cmp_task and all its children are started
<%= indent %>        # and can be manipulated

<%= indent %>        # Task contexts are stubs, so you can read input ports and
<%= indent %>        # write output ports by accessing them with e.g.
<%= indent %>        # cmp_task.my_child.orocos_task.an_output.write test_sample

<%= indent %>        # If you expect a sample to be received by one of the children, use
<%= indent %>        # sample = assert_has_one_new_sample(cmp_task.my_child.an_input_port)
<%= indent %>        # assert_equal 10, sample.value
<%= indent %>    end
<%= indent %>end
<%= close %>
