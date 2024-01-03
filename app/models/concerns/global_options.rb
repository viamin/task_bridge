# frozen_string_literal: true

module GlobalOptions
  extend ActiveSupport::Concern

  def options
    default_options.merge({
      max_age_timestamp: default_options[:max_age].zero? ? nil : Chronic.parse("#{default_options[:max_age]} ago"),
      uses_personal_tags: default_options[:work_tags].blank?,
      sync_started_at: Time.now.strftime("%Y-%m-%d %I:%M%p"),
      logger: StructuredLogger.new(log_file: default_options[:log_file], service_names: default_options[:services]),
      primary_service: "#{default_options[:primary]}::Service".safe_constantize
    })
  end

  private

  def default_options
    {
      primary: Chamber.dig!(:task_bridge, :primary_service),
      tags: Chamber.dig!(:task_bridge, :sync, :tags),
      personal_tags: Chamber.dig(:task_bridge, :personal_tags),
      work_tags: Chamber.dig(:task_bridge, :work_tags),
      services: Chamber.dig!(:task_bridge, :sync, :services),
      list: Chamber.dig(:google, :tasks_list),
      repositories: Chamber.dig(:github, :repositories)&.split(","),
      reminders_mapping: Chamber.dig(:reminders, :list_mapping),
      max_age: Chamber.dig!(:task_bridge, :sync, :max_age).to_i,
      update_ids_for_existing: Chamber.dig!(:task_bridge, :update_ids_for_existing_items),
      delete: Chamber.dig!(:task_bridge, :delete_completed),
      only_from_primary: false,
      only_to_primary: false,
      pretend: false,
      quiet: false,
      force: false,
      verbose: false,
      log_file: Chamber.dig!(:task_bridge, :log_file),
      debug: Chamber.dig!(:task_bridge, :debug),
      console: false,
      history: false,
      testing: false
    }
  end
end
