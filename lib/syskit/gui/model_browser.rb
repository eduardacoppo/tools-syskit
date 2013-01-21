require 'syskit/gui/model_selector'
require 'syskit/gui/model_views'
require 'syskit/gui/exception_view'
module Syskit
    module GUI
        # Widget that allows to browse the currently available models and
        # display information about them
        class ModelBrowser < Qt::Widget
            # Visualization and selection of models in the Ruby constant
            # hierarchy
            attr_reader :model_selector

            def initialize(main = nil)
                super

                main_layout = Qt::VBoxLayout.new(self)

                menu_layout = Qt::HBoxLayout.new
                main_layout.add_layout(menu_layout)
                central_layout = Qt::HBoxLayout.new
                main_layout.add_layout(central_layout, 3)
                splitter = Qt::Splitter.new(self)
                central_layout.add_widget(splitter)
                exception_view = ExceptionView.new
                main_layout.add_widget(exception_view, 1)


                btn_reload_models = Qt::PushButton.new("Reload", self)
                menu_layout.add_widget(btn_reload_models)
                btn_reload_models.connect(SIGNAL(:clicked)) do
                    Roby.app.clear_exceptions
                    Roby.app.reload_models
                    exception_view.exceptions = Roby.app.registered_exceptions
                    model_selector.reload
                end
                menu_layout.add_stretch(1)
                exception_view.exceptions = Roby.app.registered_exceptions

                add_central_widgets(splitter)
            end

            def add_central_widgets(splitter)
                @model_selector = ModelSelector.new(splitter)
                splitter.add_widget(model_selector)

                views = Hash[
                    Syskit::Models::TaskContext => [ModelViews::TaskContext],
                    Syskit::Models::Composition => [ModelViews::Composition],
                    Syskit::Models::DataServiceModel => [ModelViews::DataService],
                    Syskit::Actions::Profile => [ModelViews::Profile]]

                # Create a central stacked layout
                display_selector = Qt::StackedWidget.new(self)
                splitter.add_widget(display_selector)
                splitter.set_stretch_factor(1, 2)
                # Pre-create all the necessary display views
                views.each do |model, view|
                    view << display_selector.add_widget(view[0].new(splitter))
                end

                model_selector.connect(SIGNAL('model_selected(QVariant)')) do |mod|
                    mod = mod.to_ruby
                    has_view = views.any? do |model, view|
                        if mod.kind_of?(model)
                            display_selector.current_index = view[1]
                        end
                    end
                    if has_view
                        display_selector.current_widget.render(mod)
                    else
                        Kernel.raise ArgumentError, "no view available for #{mod.class} (#{mod})"
                    end
                end
            end

            # (see ModelSelector#select_by_module)
            def select_by_path(*path)
                model_selector.select_by_path(*path)
            end

            # (see ModelSelector#select_by_module)
            def select_by_module(model)
                model_selector.select_by_module(model)
            end

            # (see ModelSelector#current_selection)
            def current_selection
                model_selector.current_selection
            end
        end
    end
end
