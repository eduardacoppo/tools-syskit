module Syskit
    module NetworkGeneration
        # Algorithm that transforms a network generated by
        # {SystemNetworkGenerator} into a deployed network
        #
        # It does not deal with adapting an existing network
        class SystemNetworkDeployer
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            # The plan this deployer is acting on
            #
            # @return [Roby::Plan]
            attr_reader :plan

            # An event logger object used to track execution
            #
            # @see {Roby::DRoby::EventLogging}
            attr_reader :event_logger

            # The solver used to track the deployed tasks vs. the original tasks
            #
            # @return [MergeSolver]
            attr_reader :merge_solver

            # The deployment group used by default
            #
            # Each subpart of the network can specify their own through
            # {Component#requirements}, in which case the new group is
            # merged into the default
            #
            # @return [Models::DeploymentGroup]
            attr_accessor :default_deployment_group

            def initialize(plan,
                           event_logger: plan.event_logger,
                           merge_solver: MergeSolver.new(plan),
                           default_deployment_group: Syskit.conf.deployment_group)

                @plan = plan
                @event_logger = event_logger
                @merge_solver = merge_solver
                @default_deployment_group = default_deployment_group
            end

            # Replace non-deployed tasks in the plan by deployed ones
            #
            # The task-to-deployment association is handled by the network's
            # deployment groups (accessible through {Component#requirements})
            # as well as the default deployment group ({#default_deployment_group})
            #
            # @param [Boolean] validate if true, {#validate_deployed_networks}
            #   will run on the generated network
            # @return [Set] the set of tasks for which the deployer could
            #   not find a deployment
            def deploy(validate: true)
                debug 'Deploying the system network'

                all_tasks = plan.find_local_tasks(TaskContext).to_a
                selected_deployments, missing_deployments =
                    select_deployments(all_tasks)
                log_timepoint 'select_deployments'

                apply_selected_deployments(selected_deployments)
                log_timepoint 'apply_selected_deployments'

                if validate
                    validate_deployed_network
                    log_timepoint 'validate_deployed_network'
                end

                missing_deployments
            end

            # Find all candidates, resolved using deployment groups in the task hierarchy
            #
            # The method falls back to the default deployment group if no
            # deployments for the task could be found in the plan itself
            #
            # @return [Set<DeploymentGroup::DeployedTask>]
            def find_all_suitable_deployments_for(task, from: task)
                candidates = from.requirements.deployment_group
                                 .find_all_suitable_deployments_for(task)
                return candidates unless candidates.empty?

                parents = from.each_parent_task.to_a
                if parents.empty?
                    return default_deployment_group
                           .find_all_suitable_deployments_for(task)
                end

                parents.each_with_object(Set.new) do |p, s|
                    s.merge(find_all_suitable_deployments_for(task, from: p))
                end
            end

            # Finds the deployments suitable for a task in a given group
            #
            # If more than one deployment matches in the group, it calls
            # {#resolve_deployment_ambiguity} to try and pick one
            #
            # @param [Component] task
            # @param [Models::DeploymentGroup] deployment_groups
            # @return [nil,DeploymentGroup::DeployedTask]
            def find_suitable_deployment_for(task)
                candidates = find_all_suitable_deployments_for(task)

                return candidates.first if candidates.size <= 1

                debug do
                    "#{candidates.size} deployments available for #{task} "\
                    "(#{task.concrete_model}), trying to resolve"
                end
                selected = log_nest(2) do
                    resolve_deployment_ambiguity(candidates, task)
                end
                if selected
                    debug { "  selected #{selected}" }
                    return selected
                else
                    debug do
                        "  deployment of #{task} (#{task.concrete_model}) "\
                        'is ambiguous'
                    end
                    return
                end
            end

            # Find which deployments should be used for which tasks
            #
            # @param [[Component]] tasks the tasks to be deployed
            # @param [Component=>Models::DeploymentGroup] the association
            #   between a component and the group that should be used to
            #   deploy it
            # @return [(Component=>Deployment,[Component])] the association
            #   between components and the deployments that should be used
            #   for them, and the list of components without deployments
            def select_deployments(tasks)
                used_deployments = Set.new
                missing_deployments = Set.new
                selected_deployments = {}

                tasks.each do |task|
                    next if task.execution_agent

                    selected = find_suitable_deployment_for(task)

                    if !selected
                        missing_deployments << task
                    elsif used_deployments.include?(selected)
                        debug do
                            machine, configured_deployment, task_name = *selected
                            "#{task} resolves to #{configured_deployment}.#{task_name} "\
                                "on #{machine} for its deployment, but it is already used"
                        end
                        missing_deployments << task
                    else
                        used_deployments << selected
                        selected_deployments[task] = selected
                    end
                end
                [selected_deployments, missing_deployments]
            end

            # Modify the plan to apply a deployment selection
            #
            # @param [Component=>Deployment] selected_deployments the
            #   component-to-deployment association
            # @return [void]
            def apply_selected_deployments(selected_deployments)
                deployment_tasks = {}
                selected_deployments.each do |task, deployed_task|
                    deployed_task, = deployed_task.instanciate(
                        plan,
                        permanent: Syskit.conf.permanent_deployments?,
                        deployment_tasks: deployment_tasks
                    )
                    debug do
                        "deploying #{task} with #{task_name} of "\
                        "#{configured_deployment.short_name} (#{deployed_task})"
                    end
                    # We MUST merge one-by-one here. Calling apply_merge_group
                    # on all the merges at once would NOT copy the connections
                    # that exist between the tasks of the "from" group to the
                    # "to" group, which is really not what we want
                    #
                    # Calling with all the mappings would be useful if what
                    # we wanted is replace a subnet of the plan by another
                    # subnet. This is not the goal here.
                    merge_solver.apply_merge_group(task => deployed_task)
                end
            end

            # Sanity checks to verify that the result of #deploy_system_network
            # is valid
            #
            # @raise [MissingDeployments] if some tasks could not be deployed
            def validate_deployed_network
                verify_all_tasks_deployed
            end

            # Verifies that all tasks in the plan are deployed
            #
            # @param [Component=>DeploymentGroup] deployment_groups which
            #   deployment groups has been used for which task. This is used
            #   to generate the error messages when needed.
            def verify_all_tasks_deployed
                not_deployed = plan.find_local_tasks(TaskContext)
                                   .not_finished.not_abstract
                                   .find_all { |t| !t.execution_agent }

                return if not_deployed.empty?

                tasks_with_candidates = {}
                not_deployed.each do |task|
                    candidates = find_all_suitable_deployments_for(task)
                    candidates = candidates.map do |deployed_task|
                        task_name = deployed_task.mapped_task_name
                        existing_tasks =
                            plan.find_local_tasks(task.model)
                                .find_all { |t| t.orocos_name == task_name }
                        [deployed_task, existing_tasks]
                    end

                    tasks_with_candidates[task] = candidates
                end
                raise MissingDeployments.new(tasks_with_candidates),
                      'there are tasks for which it exists no deployed equivalent: '\
                      "#{not_deployed.map { |m| "#{m}(#{m.orogen_model.name})" }}"
            end

            # Try to resolve a set of deployment candidates for a given task
            #
            # @param [Array<(String,Model<Deployment>,String)>] candidates set
            #   of deployment candidates as
            #   (process_server_name,deployment_model,task_name) tuples
            # @param [Syskit::TaskContext] task the task context for which
            #   candidates are possible deployments
            # @return [(Model<Deployment>,String),nil] the resolved
            #   deployment, if finding a single best candidate was possible, or
            #   nil otherwise.
            def resolve_deployment_ambiguity(candidates, task)
                if task.orocos_name
                    debug { "#{task} requests orocos_name to be #{task.orocos_name}" }
                    resolved =
                        candidates
                        .find do |deployed_task|
                            deployed_task.mapped_task_name == task.orocos_name
                        end
                    unless resolved
                        debug { "cannot find requested orocos name #{task.orocos_name}" }
                    end
                    return resolved
                end

                hints = task.deployment_hints
                debug { "#{task}.deployment_hints: #{hints.map(&:to_s).join(', ')}" }
                # Look to disambiguate using deployment hints
                resolved = candidates.find_all do |deployed_task|
                    task.deployment_hints.any? do |hint|
                        hint == deployed_task.configured_deployment ||
                            hint === deployed_task.mapped_task_name
                    end
                end

                return resolved.first if resolved.size == 1

                info do
                    info { "ambiguous deployment for #{task} (#{task.model})" }
                    candidates.each do |deployment_model, task_name|
                        info do
                            "  #{task_name} of #{deployment_model.short_name} "\
                            "on #{deployment_model.process_server_name}"
                        end
                    end
                    break
                end
                nil
            end
        end
    end
end
