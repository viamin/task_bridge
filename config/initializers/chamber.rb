# frozen_string_literal: true

# Chamber automatically loads settings via its built-in Rails railtie
# (Chamber::Integrations::Rails), which calls Chamber.load with
# basepath: Rails.root.join('config') and namespaces for environment
# and hostname. This initializer verifies the settings loaded correctly
# and provides a hook point for any future customization.
#
# Settings file: config/settings.yml
# See: https://github.com/thekompanee/chamber

Rails.application.config.after_initialize do
  Chamber.dig!(:task_bridge, :primary_service)
rescue Chamber::MissingSettingError => e
  raise "Chamber failed to load settings from config/settings.yml: #{e.message}"
end
