module Syskit
    module Models
        # Base functionality for model classes that deal with oroGen models
        module OrogenBase
            # [Hash{Orocos::Spec::TaskContext => TaskContext}] a cache of
            # mappings from oroGen task context models to the corresponding
            # Syskit task context model
            attribute(:orogen_model_to_syskit_model) { Hash.new }

            def register_submodel(klass)
                super
                orogen_model_to_syskit_model[klass.orogen_model] = klass
            end

            def deregister_submodels(set)
                set.each do |m|
                    orogen_model_to_syskit_model.delete(m.orogen_model)
                    needs_removal =
                        begin
                            m == constant("::#{m.name}")
                        rescue NameError
                        end

                    if needs_removal
                        namespace, basename = m.name.split('::')
                        Object.const_get(namespace).send(:remove_const, basename)
                    end
                end
                super
            end

            # Checks whether a syskit model exists for the given orogen model
            def has_model_for?(orogen_model)
                !!orogen_model_to_syskit_model[orogen_model]
            end

            # Finds the Syskit model that represents an oroGen model with that
            # name
            def find_model_from_orogen_name(name)
                orogen_model_to_syskit_model.each do |orogen_model, syskit_model|
                    if orogen_model.name == name
                        return syskit_model
                    end
                end
                nil
            end

            # Return the syskit model that represents the given oroGen model
            #
            # @param orogen_model the oroGen model
            # @return [Syskit::TaskContext,Syskit::Deployment,nil] the
            #   corresponding syskit model, or nil if there are none registered
            def find_model_by_orogen(orogen_model)
                orogen_model_to_syskit_model[orogen_model]
            end

            # Returns the syskit model for the given oroGen model
            #
            # @raise ArgumentError if no syskit model exists 
            def model_for(orogen_model)
                if m = find_model_by_orogen(orogen_model)
                    return m
                else raise ArgumentError, "there is no syskit model for #{orogen_model.name}"
                end
            end
        end
    end

end
