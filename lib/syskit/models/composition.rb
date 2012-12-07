module Syskit
    module Models
        # Model-level instances and attributes for compositions
        #
        # See the documentation of Model for an explanation of the *Model
        # modules.
        module Composition
            include Base
            include Component

            # The set of configurations declared with #conf
            attr_reader :conf

            # [SpecializationManager] the object that manages all
            # specializations defined on this composition model
            attribute(:specializations) { SpecializationManager.new(self) }

            # The composition children
            #
            # @key_name child_name
            # @return [Hash<String,CompositionChild>]
            define_inherited_enumerable(:child, :children, :map => true) { Hash.new }

            define_inherited_enumerable(:child_constraint, :child_constraints, :map => true) { Hash.new { |h, k| h[k] = Array.new } }

            # Method that maps connections from this composition's parent models
            # to this composition's own interface
            #
            # It is called as needed when calling {#each_explicit_connection}
            def promote_explicit_connection(connections)
                children, mappings = *connections

                mappings_out =
                    if child_out = self.children[children[0]]
                        child_out.port_mappings
                    else Hash.new
                    end
                mappings_in =
                    if child_in = self.children[children[1]]
                        child_in.port_mappings
                    else Hash.new
                    end

                mapped = Hash.new
                mappings.each do |(port_name_out, port_name_in), options|
                    port_name_out = (mappings_out[port_name_out] || port_name_out)
                    port_name_in  = (mappings_in[port_name_in]   || port_name_in)
                    mapped[[port_name_out, port_name_in]] = options
                end
                [children, mapped]
            end

            # The set of connections specified by the user for this composition
            #
            # @return [Hash{(String,String)=>{(String,String)=>Hash}}] the set
            # of connections defined on this composition model. The first level
            # is a mapping from the (output child name, input child name) to a
            # set of connections. The set of connections is specified as a
            # mapping from the output port name (on the output child) and the
            # input port name (on the input child) to the desired connection policy.
            #
            # Empty connection policies means "autodetect policy"
            define_inherited_enumerable(:explicit_connection, :explicit_connections) { Hash.new { |h, k| h[k] = Hash.new } }

            # [ValueSet<Model<Composition>>] the composition models that are parent to this one
            attribute(:parent_models) { ValueSet.new }

            # The root composition model in the specialization hierarchy
            def root_model; self end

            ##
            # :attr: specialized_children
            #
            # The set of specializations that are applied from the root of the
            # model graph up to this model
            #
            # It is empty for composition models that are not specializations
            attribute(:specialized_children) { Hash.new }

            ##
            # :attr: specialized_children
            #
            # The set of specializations that are applied from the root of the
            # model graph up to this model
            attribute(:applied_specializations) { Set.new }

            # (see SpecializationManager#specialize)
            def specialize(options = Hash.new, &block)
                specializations.specialize(options, &block)
            end

            # Returns true if this composition model is a model created by
            # specializing another one on +child_name+ with +child_model+
            #
            # For instance:
            #
            #   composition 'Compo' do
            #       add Source
            #       add Sink
            #
            #       submodel = specialize Sink, Logger
            #
            #       submodel.specialized_on?('Sink', Logger) # => true
            #       submodel.specialized_on?('Sink', Test) # => false
            #       submodel.specialized_on?('Source', Logger) # => false
            #   end
            def specialized_on?(child_name, child_model)
                specialized_children.has_key?(child_name) &&
                    specialized_children[child_name].include?(child_model)
            end

            # Returns true if +self+ is a parent model of +child_model+
            def parent_model_of?(child_model)
                (child_model < self) ||
                    specializations.values.include?(child_model)
            end

            # Enumerates the input ports that are defined on this composition,
            # i.e.  the ports created by #export
            def each_input_port
                if block_given?
                    each_exported_input do |_, p|
                        yield(p)
                    end
                else
                    enum_for(:each_input_port)
                end
            end

            # Returns the input port of this composition named +name+, or nil if
            # there are none
            def find_input_port(name); find_exported_input(name) end

            # Enumerates the output ports that are defined on this composition,
            # i.e.  the ports created by #export
            def each_output_port
                if block_given?
                    each_exported_output do |_, p|
                        yield(p)
                    end
                else
                    enum_for(:each_output_port)
                end
            end

            # Returns the output port of this composition named +name+, or nil
            # if there are none
            def find_output_port(name); find_exported_output(name) end

            # Internal helper to add a child to the composition
            def add_child(name, child_models, dependency_options)
                name = name.to_str
                dependency_options = Roby::TaskStructure::Dependency.validate_options(dependency_options)

                # We do NOT check for an already existing definition. The reason
                # is that specialization (among other) will add a default child,
                # that may be overriden by the composition's owner. Either to
                # set arguments, or to have a specialization over an aspect of a
                # data service use a more specific task model in the specialized
                # composition.
                #
                # Anyway, the remainder checks that the new definition is a
                # valid overloading of the previous one.
                
                parent_model = find_child(name) || CompositionChild.new(self, name)
                child_models = Models.merge_model_lists(child_models, parent_model.base_models)
                dependency_options = Roby::TaskStructure::DependencyGraphClass.
                    merge_dependency_options(parent_model.dependency_options, dependency_options)

                result = CompositionChild.new(self, name, child_models, dependency_options, parent_model)
                Models.debug do
                    Models.debug "added child #{name} to #{short_name}"
                    Models.debug "  with models #{result.models.map(&:short_name).join(", ")}"
                    if !parent_model.models.empty?
                        Models.debug "  updated from #{parent_model.models.map(&:short_name).join(", ")}"
                    end
                    if !result.port_mappings.empty?
                        Models.debug "  port mappings"
                        Models.log_nest(4) do
                            result.port_mappings.each_value do |mappings|
                                Models.log_pp(:debug, mappings)
                            end
                        end
                    end
                    break
                end
                children[name] = result
            end

            # Overloads an existing child with a new model and/or options
            #
            # This is 100% equivalent to
            #
            #   add model, (:as => name).merge(options)
            #
            # The only (important) difference is that it checks that +name+ is
            # indeed an existing child, and allows people that read the
            # composition model to understand the intent
            def overload(name, model, options = Hash.new)
                if !find_child(name)
                    raise ArgumentError, "#{name} is not an existing child of #{short_name}"
                end
                add(model, options.merge(:as => name))
            end

            # Add an element in this composition.
            #
            # This method adds a new element from the given component or data
            # service model. Raises ArgumentError if +model+ is of neither type.
            #
            # If an 'as' option is provided, this name will be used as the child
            # name. Otherwise, the basename of 'model' is used as the child
            # name. It will raise ArgumentError if the name is already used in this
            # composition.
            #
            # Returns the child definition as a CompositionChild instance. This
            # instance can also be accessed with Composition.[]
            #
            # For instance
            #   
            #   orientation_provider = data_service 'Orientation'
            #   # This child will be naned 'Orientation'
            #   composition.add orientation_provider
            #   # This child will be named 'imu'
            #   composition.add orientation_provider, :as => 'imu'
            #   composition['Orientation'] # => CompositionChild representing
            #                              # the first element
            #   composition['imu'] # => CompositionChild representing the second
            #                      # element
            #
            # == Subclassing
            #
            # If the composition model is a subclass of another composition
            # model, then +add+ can be used to override a child definition. In
            # if it the case, if +model+ is a component model, then it has to be
            # a subclass of any component model that has been used in the parent
            # composition. Otherwise, #add raises ArgumentError
            #
            # For instance,
            #
            #   raw_imu_readings = data_service "RawImuReadings"
            #   submodel = composition.new_submodel 'Foo'
            #   # This is fine as +raw_imu_readings+ and +orientation_provider+
            #   # can be combined. +submodel+ will require 'imu' to provide both
            #   # a RawImuReadings data service and a Orientation data service.
            #   submodel.add submodel, :as => 'imu' 
            #
            # Now, let's assume that 'imu' was declared as
            #
            #   composition.add XsensImu::Task, :as => 'imu'
            #
            # where XsensImu::Task is an actual component that drives IMUs from
            # the Xsens company. Then,
            #
            #   submodel.add DfkiImu::Task, :as => 'imu'
            #
            # would be invalid as the 'imu' child cannot be both an XsensImu and
            # DfkiImu task. In this case, you would need to define a common data
            # service that is provided by both components.
            def add(models, options = Hash.new)
                if !models.respond_to?(:each)
                    models = [models]
                end
                models = models.to_value_set

                wrong_type = models.find do |m|
                    !m.kind_of?(Roby::TaskModelTag) && !(m.kind_of?(Class) && m < Syskit::Component)
                end
                if wrong_type
                    raise ArgumentError, "wrong model type #{wrong_type.class} for #{wrong_type}"
                end

                if models.size == 1
                    if default_name = models.find { true }.name
                        default_name = default_name.snakecase
                    end
                end
                options, dependency_options = Kernel.filter_options options,
                    :as => default_name

                if !options[:as]
                    raise ArgumentError, "you must provide an explicit name with the :as option"
                end

                add_child(options[:as], models, dependency_options)
            end

            # Returns this composition's main task
            #
            # The main task is the task that performs the composition's main
            # goal (if there is one). The composition will terminate
            # successfully whenever the main task finishes successfully.
            def main_task
                if @main_task then @main_task
                elsif superclass.respond_to?(:main_task)
                    superclass.main_task
                end
            end

            # DEPRECATED. Use #add_main instead.
            def add_main_task(models, options = Hash.new) # :nodoc:
                add_main(models, options)
            end

            # Adds the given child, and marks it as the task that provides the
            # main composition's functionality.
            #
            # What is means in practice is that the composition will terminate
            # successfully when this child terminates successfully
            def add_main(models, options = Hash.new)
                if main_task
                    raise ArgumentError, "this composition already has a main task child"
                end
                @main_task = add(models, options)
            end

            # Returns true if this composition model is a specialized version of
            # its superclass, and false otherwise
            def is_specialization?; false end

            # See CompositionSpecialization#specialized_on?
            def specialized_on?(child_name, child_model); false end
            
            def pretty_print(pp) # :nodoc:
                pp.text "#{root_model.name}:"

                specializations = specialized_children.to_a
                if !specializations.empty?
                    pp.text "Specialized on:"
                    pp.nest(2) do
                        specializations.each do |key, selected_models|
                            pp.breakable
                            pp.text "#{key}: "
                            pp.nest(2) do
                                pp.seplist(selected_models) do |m|
                                    m.pretty_print(pp)
                                end
                            end
                        end
                    end
                end
                
                data_services = each_data_service.to_a
                if !data_services.empty?
                    pp.nest(2) do
                        pp.breakable
                        pp.text "Data services:"
                        pp.nest(2) do
                            data_services.sort_by(&:first).
                                each do |name, ds|
                                    pp.breakable
                                    pp.text "#{name}: #{ds.model.name}"
                                end
                        end
                    end
                end
            end

            # Autoconnects the outputs listed in +child_outputs+ to the inputs
            # in child_inputs. +exclude_connections+ is a list of connections
            # whose input ports should be ignored in the autoconnection process.
            #
            # +child_outputs+ and +child_inputs+ are mappings of the form
            #
            #   type_name => [child_name, port_name]
            #
            # +exclude_connections+ is using the same format than the values
            # returned by each_explicit_connection (i.e. how connections are
            # stored in the DataFlow graph), namely a mapping of the form
            #
            #   (child_out_name, child_in_name) => mappings
            #
            # Where +mappings+ is
            #
            #   [port_out, port_in] => connection_policy
            #
            def autoconnect_children(child_output_ports, child_input_ports, exclude_connections)
                result = Hash.new { |h, k| h[k] = Hash.new }

                child_outputs = Hash.new { |h, k| h[k] = Array.new }
                child_output_ports.each do |p|
                    child_outputs[p.type_name] << [p.component_model.child_name, p.name]
                end
                child_inputs = Hash.new { |h, k| h[k] = Array.new }
                child_input_ports.each do |p|
                    child_inputs[p.type_name] << [p.component_model.child_name, p.name]
                end
                existing_inbound_connections = Set.new
                exclude_connections.each do |(_, child_in), mappings|
                    mappings.each_key do |_, port_in|
                        existing_inbound_connections << [child_in, port_in]
                    end
                end

                # Now create the connections
                child_inputs.each do |typename, in_ports|
                    in_ports.each do |in_child_name, in_port_name|
                        # Ignore this port if there is an explicit inbound connection that involves it
                        next if existing_inbound_connections.include?([in_child_name, in_port_name])

                        # Now remove the potential connections to the same child
                        # We need to #dup as we modify the hash (delete_if just
                        # below)
                        out_ports = child_outputs[typename].dup
                        out_ports.delete_if do |out_child_name, out_port_name|
                            out_child_name == in_child_name
                        end
                        next if out_ports.empty?

                        # If it is ambiguous, check first if there is only one
                        # candidate that has the same name. If there is one,
                        # pick it. Otherwise, raise an exception
                        if out_ports.size > 1
                            # Check for identical port name
                            same_name = out_ports.find_all { |_, out_port_name| out_port_name == in_port_name }
                            if same_name.size == 1
                                out_ports = same_name
                            end

                            # Check for child name
                            includes_child_name = out_ports.find_all do |out_child_name, _|
                                in_port_name =~ /#{Regexp.quote(out_child_name)}/
                            end
                            if includes_child_name.size == 1
                                out_ports = includes_child_name
                            end
                        end

                        if out_ports.size > 1
                            error = AmbiguousAutoConnection.new(
                                self, typename,
                                [[in_child_name, in_port_name]],
                                out_ports)

                            out_port_names = out_ports.map { |child_name, port_name| "#{child_name}.#{port_name}" }
                            raise error, "multiple output candidates in #{name} for the input port #{in_child_name}.#{in_port_name} (of type #{typename}): #{out_port_names.join(", ")}"
                        end

                        out_port = out_ports.first
                        result[[out_port[0], in_child_name]][ [out_port[1], in_port_name] ] = Hash.new
                    end
                end

                Models.debug do
                    Models.debug "automatic connection result in #{short_name}"
                    result.each do |(out_child, in_child), connections|
                        connections.each do |(out_port, in_port), policy|
                            Models.debug "    #{out_child}:#{out_port} => #{in_child}:#{in_port} (#{policy})"
                        end
                    end
                    break
                end
                result
            end

            # Returns the set of connections that should be created during the
            # instanciation of this composition model.
            #
            # The returned value is a mapping:
            #
            #   [source_name, sink_name] =>
            #       {
            #           [source_port_name0, sink_port_name1] => connection_policy,
            #           [source_port_name0, sink_port_name1] => connection_policy
            #       }
            #       
            def connections
                result = Hash.new { |h, k| h[k] = Hash.new }

                # In the following, 'key' is [child_source, child_dest] and
                # 'mappings' is [port_source, port_sink] => connection_policy
                each_explicit_connection do |key, mappings|
                    result[key].merge!(mappings)
                end
                result
            end

            # Export the given port to the boundary of the composition (it
            # becomes a composition port). By default, the composition port has
            # the same name than the exported port. This name can be overriden
            # by the :as option
            #
            # For example, if one does:
            #    
            #    composition 'Test' do
            #       source = add 'Source'
            #       export source.output
            #       export source.output, :as => 'output2'
            #    end
            #
            # Then the resulting composition gets 'output' and 'output2' output
            # ports that can further be used in other connections (or
            # autoconnections):
            #    
            #    composition 'Global' do
            #       test = add 'Test'
            #       c = add 'Component'
            #       connect test.output2 => c.input
            #    end
            #
            def export(port, options = Hash.new)
                options = Kernel.validate_options options, :as => port.name
                name = options[:as].to_str
                if self.find_port(name)
                    raise ArgumentError, "there is already a port named #{name} on #{short_name}"
                end

                case port
                when InputPort
                    exported_inputs[name] = port
                when OutputPort
                    exported_outputs[name] = port
                else
                    raise TypeError, "invalid port #{port.port} of type #{port.port.class}"
                end
                find_port(name)
            end

            # Returns true if +port_model+, which has to be a child's port, is
            # exported in this composition
            #
            # @return [Boolean]
            # @see #export
            #
            # @example
            #
            #   class C < Syskit::Composition
            #     add srv, :as => 'srv'
            #     export srv.output_port
            #   end
            #
            #   C.exported_port?(C.srv_child.output_port) => true
            #
            def exported_port?(port)
                each_exported_output do |name, p|
                    return true if p == port
                end
                each_exported_input do |name, p|
                    return true if p == port
                end
                false
            end

            # Returns the port named 'name' in this composition
            #
            # See #export to create ports on a composition
            def find_port(name)
                name = name.to_str
                (find_output_port(name) || find_input_port(name))
            end

            # Returns the composition's output port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def find_output_port(name)
                name = name.to_str
                if p = find_exported_output(name.to_str)
                    return OutputPort.new(self, p.orogen_model, name)
                end
            end

            # Returns the composition's input port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def find_input_port(name)
                name = name.to_str
                if p = find_exported_input(name.to_str)
                    return InputPort.new(self, p.orogen_model, name)
                end
            end

            # Returns true if +name+ is a valid dynamic input port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def has_dynamic_input_port?(name); false end

            # Returns true if +name+ is a valid dynamic output port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def has_dynamic_output_port?(name); false end

            # Explicitly create the given connections between children of this
            # composition.
            #
            # Example:
            #   composition 'Test' do
            #       source = add 'Source'
            #       sink   = add 'Sink'
            #       connect source.output => sink.input, :type => :buffer
            #   end
            #
            # Explicit connections always have precedence on automatic
            # connections. See #autoconnect for automatic connection handling
            def connect(mappings)
                options = Hash.new
                mappings.delete_if do |a, b|
                    if a.respond_to?(:to_str)
                        options[a] = b
                    end
                end
                if !options.empty?
                    options = Kernel.validate_options options, Orocos::Port::CONNECTION_POLICY_OPTIONS
                end
                mappings.each do |out_p, in_p|
                    child_inputs  = Array.new
                    child_outputs = Array.new

                    # Flags used to mark whether in_p resp. out_p have been
                    # explicitely given as ports or as child task. It is used to
                    # generate different error messages.
                    in_explicit, out_explicit = false

                    case out_p
                    when OutputPort
                        out_explicit = true
                        child_outputs << out_p
                    when CompositionChild
                        out_p.each_output_port do |p|
                            child_outputs << p
                        end
                    when InputPort
                        raise ArgumentError, "#{out_p.name} is an input port of #{out_p.component_model.child_name}. The correct syntax is 'connect output => input'"
                    else
                        raise ArgumentError, "#{out_p} is neither an input or output port. The correct syntax is 'connect output => input'"
                    end

                    case in_p
                    when InputPort
                        in_explicit = true
                        child_inputs << in_p
                    when CompositionChild
                        in_p.each_input_port do |p|
                            if !in_p
                                raise
                            end
                            child_inputs << p
                        end
                    when OutputPort
                        raise ArgumentError, "#{in_p.name} is an output port of #{in_p.component_model.child_name}. The correct syntax is 'connect output => input'"
                    else
                        raise ArgumentError, "#{in_p} is neither an input or output port. The correct syntax is 'connect output => input'"
                    end

                    result = autoconnect_children(child_outputs, child_inputs, each_explicit_connection.to_a)
                    # No connections found. This is an error, as the user
                    # probably expects #connect to create some, so raise the
                    # corresponding exception
                    if result.empty?
                        raise AmbiguousChildConnection.new(self, out_p, in_p)
                    end

                    explicit_connections.merge!(result) do |k, v1, v2|
                        v1.merge!(v2)
                    end
                end
            end

            # Returns the set of constraints that exist for the given child.
            # I.e. the set of types that, at instanciation time, the chosen
            # child must provide.
            #
            # See #constrain
            def constraints_for(child_name)
                result = ValueSet.new
                each_child_constraint(child_name, false) do |constraint_set|
                    result |= constraint_set.to_value_set
                end
                result
            end

            # Verifies that +selected_model+ is an acceptable selection for
            # +child_name+ on +self+. Raises InvalidSelection if it is not the case,
            # and ArgumentError if the specified child is not a child of this
            # composition.
            #
            # See also #acceptable_selection?
            def verify_acceptable_selection(child_name, selected_model, user_call = true) # :nodoc:
                dependent_model = find_child(child_name)
                if !dependent_model
                    raise ArgumentError, "#{child_name} is not the name of a child of #{self}"
                end

                dependent_model = dependent_model.models
                if !selected_model.fullfills?(dependent_model)
                    throw :invalid_selection if !user_call
                    raise InvalidSelection.new(self, child_name, selected_model, dependent_model),
                        "cannot select #{selected_model} for #{child_name}: [#{selected_model}] is not a specialization of [#{dependent_model.map(&:short_name).join(", ")}]"
                end
            end

            # Returns true if +selected_child+ is an acceptable selection for
            # +child_name+ on +self+
            #
            # See also #verify_acceptable_selection
            def acceptable_selection?(child_name, selected_child) # :nodoc:
                catch :invalid_selection do
                    verify_acceptable_selection(child_name, selected_child, false)
                    return true
                end
                return false
            end

            # The list of names that will be used by this model as keys in a
            # DependencyInjection object,
            #
            # For compositions, this is the list of children names
            def dependency_injection_names
                each_child.map(&:first)
            end

            # Computes the required models and task instances for each of the
            # composition's children. It returns two mappings for the form
            #
            #   child_name => [child_model, child_task, port_mappings]
            #
            # where +child_name+ is the name of the child, +child_model+ is the
            # actual selected model and +child_task+ the actual selected task.
            #
            # +child_task+ will be non-nil only if the user specifically
            # selected a task.
            #
            # The first returned mapping is the set of explicit selections (i.e.
            # selections that are specified by +selection+) and the second one
            # is the complete result for all the composition children.
            def find_children_models_and_tasks(context, user_call = true) # :nodoc:
                explicit = Hash.new
                result   = Hash.new
                each_child do |child_name, child_requirements|
                    selected_child = context.instance_selection_for(child_name, child_requirements)
                    Models.debug do
                        Models.debug "selected #{child_name}:"
                        Models.log_nest(2) do
                            Models.log_pp(:debug, selected_child)
                            Models.debug "on the basis of"
                            Models.log_nest(2) do
                                Models.log_pp(:debug, context.current_state)
                            end
                        end
                        break
                    end

                    if context.has_selection_for?(child_name)
                        explicit[child_name] = selected_child
                    end
                    result[child_name] = selected_child
                end

                return explicit, result
            end

            # Returns the set of specializations that match the given dependency
            # injection context
            def narrow(context)
                user_selection, _ = find_children_models_and_tasks(context)

                spec = Hash.new
                user_selection.each { |name, selection| spec[name] = selection.requirements.models }
                find_suitable_specialization(spec)
            end

            # This returns an InstanciatedComponent object that can be used in
            # other #use statements in the deployment spec
            #
            # For instance,
            #
            #   add(Cmp::CorridorServoing).
            #       use(Cmp::Odometry.use(XsensImu::Task))
            #
            def use(*spec)
                InstanceRequirements.new([self]).use(*spec)
            end

            # Instanciates a task for the required child
            def instanciate_child(engine, context, self_task, child_name, selected_child) # :nodoc:
                Models.debug do
                    Models.debug "instanciating child #{child_name}"
                    Models.log_nest 2
                    break
                end

                child_arguments = selected_child.required.arguments
                child_arguments.each_key do |key|
	            value = child_arguments[key]
                    if value.respond_to?(:resolve)
                        child_arguments[key] = value.resolve(self)
                    end
                end

                selected_child.instanciate(engine, context, :task_arguments => child_arguments)
            ensure
                Models.debug do
                    Models.log_nest -2
                    break
                end
            end

            def instanciate_connections(self_task, selected_children, children_tasks)
                # The set of connections we must create on our children. This is
                # self.connections on which we will apply port mappings for the
                # instanciated children
                each_explicit_connection do |(out_name, in_name), conn|
                    if (out_task = children_tasks[out_name]) && (in_task = children_tasks[in_name])
                        child_out    = selected_children[out_name]
                        child_in     = selected_children[in_name]
                        mappings_out = child_out.port_mappings
                        mappings_in  = child_in.port_mappings

                        mapped = Hash.new
                        conn.each do |(port_out, port_in), policy|
                            mapped_port_out = mappings_out[port_out] || port_out
                            mapped_port_in  = mappings_in[port_in] || port_in
                            mapped[[mapped_port_out, mapped_port_in]] = policy
                        end
                            
                        out_task.connect_ports(in_task, mapped)
                    end
                end

                each_exported_input do |export_name, port|
                    child_name = port.component_model.child_name
                    if child_task = children_tasks[child_name]
                        child = selected_children[child_name]
                        self_task.forward_ports(child_task, [export_name, child.port_mappings[port.actual_name]] => Hash.new)
                    end
                end
                each_exported_output do |export_name, port|
                    child_name = port.component_model.child_name
                    if child_task = children_tasks[child_name]
                        child = selected_children[child_name]
                        child_task.forward_ports(self_task, [child.port_mappings[port.actual_name], export_name] => Hash.new)
                    end
                end
            end

            # Returns a Composition task with instanciated children. If
            # specializations have been specified on this composition, the
            # return task will be of the most specialized model that matches the
            # selection. See #specialize for more information.
            #
            # The :selection argument, if set, specifies explicit selections for
            # the composition's children. In its generality, the argument is a
            # hash which maps a child selector to a selected model.
            #
            # The selected model can be:
            # * a task model, a data service model or a device model
            # * a device name as declared on Robot.devices
            # * a task name as given to Engine#add
            #
            # In any case, the selected model must be compatible with the
            # child's definition and the additional constraints that have been
            # specified on it (see #constrain).
            #
            # The child selector can be (by order of precedence)
            # * a child name
            # * a child_name.child_of_child_name construct. In that case, the
            #   engine will search for a composition that can be used in place
            #   of +child_name+, and has a +child_name_of_child+ child that
            #   matches the selection.
            # * a child model or model name, in which case it will match the
            #   children of +self+ whose definition matches the given model.
            #
            def instanciate(engine, context, arguments = Hash.new)
                Models.debug do
                    Models.debug "instanciating #{short_name} with"
                    Models.log_nest(2)
                    Roby.log_pp(context, Models, :debug)
                    break
                end

                arguments = Kernel.validate_options arguments, :as => nil, :task_arguments => Hash.new, :specialize => true
                if arguments[:specialize] && root_model != self
                    return root_model.instanciate(engine, context, arguments)
                end

                # Find what we should use for our children. +explicit_selection+
                # is the set of children for which a selection existed and
                # +selected_models+ all the models we should use
                explicit_selections, selected_models =
                    find_children_models_and_tasks(context)

                if arguments[:specialize]
                    # Find the specializations that apply. We use
                    # +explicit_selections+ so that we don't under-specialize.
                    # For instance, if a composition has
                    #   add(Srv::BaseService, :as => 'child')
                    #
                    # And no selection exists in 'context' for that child, then
                    #   explicit_selection['child'] == nil
                    # while
                    #   selected_models['child'] == Srv::BaseService
                    #
                    # In the second case, any specialization that does not match
                    # Srv::BaseService for child would be rejected.
                    specialized_model = specializations.matching_specialized_model(explicit_selection.map_value { |sel| [sel] })
                    if specialized_model != self
                        return specialized_model.instanciate(engine, context, arguments.merge(:specialize => false))
                    end
                end

                # First of all, add the task for +self+
                engine.plan.add(self_task = new(arguments[:task_arguments]))
                conf = if self_task.has_argument?(:conf)
                           self_task.conf(self_task.arguments[:conf])
                       else Hash.new
                       end

                removed_optional_children = Set.new

                # We need the context without the child selections for the
                # composition itself. Dup the current context and pop the
                # composition use flags
                child_selection_context = context.dup
                composition_use_flags = child_selection_context.pop
                child_use_flags = Hash.new

                # Finally, instanciate the missing tasks and add them to our
                # children
                children_tasks = Hash.new
                remaining_children_models = selected_models.dup
                while !remaining_children_models.empty?
                    current_size = remaining_children_models.size
                    remaining_children_models.delete_if do |child_name, selected_child|
                        # Get out of the selections the parts that are
                        # relevant for our child. We only pass on the
                        # <child_name>.blablabla form, everything else is
                        # removed
                        child_user_selection = Hash.new
                        composition_use_flags.added_info.explicit.each do |name, sel|
                            if name =~ /^#{child_name}\.(.*)$/
                                child_user_selection[$1] = sel
                            end
                        end
                        child_selection_context.push(child_user_selection.merge(child_use_flags))
                        child_task = instanciate_child(engine, child_selection_context,
                                                       self_task, child_name, selected_child)
                        child_selection_context.pop
                        if !child_task
                            # Cannot instanciate yet, probably because the
                            # instantiation of this child depends on other
                            # children that are not yet instanciated
                            next(false)
                        end

                        if child_task.abstract? && find_child(child_name).optional?
                            Models.debug "not adding optional child #{child_name}"
                            removed_optional_children << child_name
                            next(true)
                        end

                        if child_conf = conf[child_name]
                            child_task.arguments[:conf] ||= child_conf
                        end

                        role = [child_name].to_set
                        children_tasks[child_name] = child_task
                        child_use_flags["parent.#{child_name}"] = child_task

                        dependent_models    = find_child(child_name).models.to_a
                        dependent_arguments = dependent_models.inject(Hash.new) do |result, m|
                            result.merge(m.meaningful_arguments(child_task.arguments))
                        end
                        if child_task.has_argument?(:conf)
                            dependent_arguments[:conf] = child_task.arguments[:conf]
                        end

                        dependency_options = find_child(child_name).dependency_options
                        dependency_options = { :success => [], :failure => [:stop], :model => [dependent_models, dependent_arguments], :roles => role }.
                            merge(dependency_options)

                        Models.info do
                            Models.info "adding dependency #{self_task}"
                            Models.info "    => #{child_task}"
                            Models.info "   options; #{dependency_options}"
                            break
                        end

                        self_task.depends_on(child_task, dependency_options)
                        self_task.child_selection[child_name] = selected_child
                        if (main = main_task) && (main.child_name == child_name)
                            child_task.each_event do |ev|
                                if !ev.terminal? && ev.symbol != :start && self_task.has_event?(ev.symbol)
                                    child_task.event(ev.symbol).forward_to self_task.event(ev.symbol)
                                end
                            end
                            child_task.success_event.forward_to self_task.success_event
                        end
                        true # it has been processed, delete from remaining_children_models
                    end
                    if remaining_children_models.size == current_size
                        raise InternalError, "cannot resolve #{child_name}"
                    end
                end

                instanciate_connections(self_task, selected_models, children_tasks)
                self_task
            ensure
                Models.debug do
                    Models.log_nest -2
                end
            end

            def to_dot(io)
                id = object_id.abs

                connections.each do |(source, sink), mappings|
                    mappings.each do |(source_port, sink_port), policy|
                        io << "C#{id}#{source}:#{source_port} -> C#{id}#{sink}:#{sink_port};"
                    end
                end

                if !is_specialization?
                    specializations = each_specialization.to_a
                    specializations.each do |spec, specialized_model|
                        specialized_model.to_dot(io)

                        specialized_model.parent_models.each do |parent_compositions|
                            parent_id = parent_compositions.object_id
                            specialized_id = specialized_model.object_id
                            io << "C#{parent_id} -> C#{specialized_id} [ltail=cluster_#{parent_id} lhead=cluster_#{specialized_id} weight=2];"
                        end
                    end
                end

                io << "subgraph cluster_#{id} {"
                io << "  fontsize=18;"
                io << "  C#{id} [style=invisible];"

                if !exported_inputs.empty? || !exported_outputs.empty?
                    inputs = exported_inputs.keys
                    outputs = exported_outputs.keys
                    label = Graphviz.dot_iolabel("Composition Interface", inputs, outputs)
                    io << "  Cinterface#{id} [label=\"#{label}\",color=blue,fontsize=15];"
                    
                    exported_outputs.each do |exported_name, port|
                        io << "C#{id}#{port.component_model.child_name}:#{port.port.name} -> Cinterface#{id}:#{exported_name} [style=dashed];"
                    end
                    exported_inputs.each do |exported_name, port|
                        io << "Cinterface#{id}:#{exported_name} -> C#{id}#{port.component_model.child_name}:#{port.port.name} [style=dashed];"
                    end
                end
                label = [short_name.dup]
                provides = each_data_service.map do |name, type|
                    "#{name}:#{type.model.short_name}"
                end
                if abstract?
                    label << "Abstract"
                end
                if !provides.empty?
                    label << "Provides:"
                    label.concat(provides)
                end
                io << "  label=\"#{label.join("\\n")}\";"
                # io << "  label=\"#{model.name}\";"
                # io << "  C#{id} [style=invisible];"
                each_child do |child_name, child_definition|
                    child_model = child_definition.models

                    task_label = child_model.map(&:short_name).join(',')
                    task_label = "#{child_name}[#{task_label}]"
                    inputs = child_model.map { |m| m.each_input_port.map(&:name) }.
                        inject(&:concat).to_a
                    outputs = child_model.map { |m| m.each_output_port.map(&:name) }.
                        inject(&:concat).to_a
                    label = Graphviz.dot_iolabel(task_label, inputs, outputs)

                    if child_model.any? { |m| !(m <= Component) || m.abstract? }
                        color = ", color=\"red\""
                    end
                    io << "  C#{id}#{child_name} [label=\"#{label}\"#{color},fontsize=15];"
                end
                io << "}"
            end

            # Create a new submodel of this composition model
            def new_submodel(options = Hash.new, &block)
                submodel = super

                return if submodel.is_specialization?
                specializations.each_specialization do |spec|
                    spec.specialization_blocks.each do |block|
                        specialize(spec.specialized_children, &block)
                    end
                end
                submodel
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block_given?
                    name = m.to_s
                    if has_child?(name = name.gsub(/_child$/, ''))
                        return find_child(name)
                    end
                end
                super
            end

            # Helper method for {#promote_exported_output} and
            # {#promote_exported_input}
            def promote_exported_port(export_name, port)
                if new_child = children[port.component_model.child_name]
                    if new_port_name = new_child.port_mappings[port.actual_name]
                        result = send(port.component_model.child_name).find_port(new_port_name)
                        result = result.dup
                        result.name = export_name
                        result
                    else
                        port
                    end
                else
                    port
                end
            end

            # Method that maps exports from this composition's parent models to
            # this composition's own interface
            #
            # It is called as needed when calling {#each_exported_output}
            def promote_exported_output(export_name, port)
                exported_outputs[export_name] = promote_exported_port(export_name, port)
            end

            # Outputs exported from components in this composition to this
            # composition's interface
            #
            # @key_name exported_port_name
            # @return [Hash<String,Port>]
            define_inherited_enumerable(:exported_output, :exported_outputs, :map => true)  { Hash.new }

            # Method that maps exports from this composition's parent models to
            # this composition's own interface
            #
            # It is called as needed when calling {#each_exported_input}
            def promote_exported_input(export_name, port)
                exported_inputs[export_name] = promote_exported_port(export_name, port)
            end

            # Inputs exported from components in this composition to this
            # composition's interface
            #
            # @key_name exported_port_name
            # @return [Hash<String,Port>]
            define_inherited_enumerable(:exported_input, :exported_inputs, :map => true)  { Hash.new }

            # Configurations defined on this composition model
            #
            # @key_name conf_name
            # @return [Hash<String,Hash<String,String>>] the mapping from a
            #   composition configuration name to the corresponding
            #   configurations that should be applied to its children
            # @see {#conf}
            define_inherited_enumerable(:configuration, :configurations, :map => true)  { Hash.new }

            # Declares a composition configuration
            #
            # Composition configurations are named selections of configurations.
            #
            # For instance, if
            #
            #   conf 'narrow',
            #       'monitoring' => ['default', 'narrow_window'],
            #       'sonar' => ['default', 'narrow_window']
            #
            # is declared, and the composition is instanciated with
            #
            #   Cmp::SonarMonitoring.use_conf('narrow')
            #
            # Then the composition children called 'monitoring' and 'sonar' will
            # be both instanciated with ['default', 'narrow_window']
            def conf(name, mappings = Hash.new)
                configurations[name] = mappings
            end

            # Reimplemented from Roby::Task to take into account the multiple
            # inheritance mechanisms that is the composition specializations
            def fullfills?(models)
                models = [models] if !models.respond_to?(:each)
                compo, normal = models.partition { |m| m <= Composition }
                if !super(normal)
                    return false
                elsif compo.empty?
                    return true
                else
                    (self <= compo.first) ||
                        compo.first.parent_model_of?(self)
                end
            end

        end
    end
end
