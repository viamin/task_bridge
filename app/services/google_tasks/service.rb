# frozen_string_literal: true

require "google/apis/tasks_v1"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class Service < Base::Service
    include AuthorizationHelpers

    attr_reader :tasks_service, :authorized

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def initialize(options: nil, tasks_service: Google::Apis::TasksV1::TasksService.new, authorization: nil)
      super(options:)
      @tasks_service = tasks_service
      @tasks_service.authorization = authorization || user_credentials_for(Google::Apis::TasksV1::AUTH_TASKS)
      @authorized = true
    rescue Signet::AuthorizationError => e
      puts "Google Tasks credentials have expired. Delete credentials.yml and re-authorize"
      puts e.full_message
      # TODO: create a task in the primary service to re-login to Google Tasks
      @authorized = false
    rescue Google::Apis::AuthorizationError => e
      puts "Google Authentication has failed. Please check authorization settings and try again."
      puts e.full_message
      # If authentication fails, skip the service
      @authorized = false
    end

    def item_class
      GoogleTasks::Task
    end

    def friendly_name
      "Google Tasks"
    end

    def sync_strategies
      [:from_primary]
    end

    def items_to_sync(*, only_modified_dates: false, **)
      debug("called", options[:debug])
      target_tasklist = tasklist
      return [] if target_tasklist.nil?

      @items_to_sync ||= {}
      @items_to_sync[only_modified_dates] ||= begin
        raw_tasks = tasks_service.list_tasks(
          target_tasklist.id,
          max_results: 100,
          # Only include tasks completed within the last week (reduces response size)
          completed_min: completed_min_timestamp,
          # Only fetch tasks modified since last sync (if we have a previous sync time)
          updated_min: last_sync_time&.iso8601
        ).items || []
        raw_tasks.map do |external_task|
          task = Task.find_or_initialize_by(external_id: external_task.id)
          task.google_task = external_task
          task.refresh_from_external!(only_modified_dates:)
        end
      end
    end

    def add_item(external_task)
      return nil if (target_tasklist = tasklist).nil?

      return external_task.flag! if external_task.respond_to?(:estimated_minutes) && external_task.estimated_minutes.nil?

      google_task_json = GoogleTasks::Task.from_external(external_task)
      google_task = Google::Apis::TasksV1::Task.new(**google_task_json)
      debug("google_task: #{google_task.pretty_inspect}", options[:debug])
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L360
      created_task = tasks_service.insert_task(target_tasklist.id, google_task)
      update_sync_data(external_task, created_task.id, created_task.self_link)
      created_task.to_h
    end

    def patch_item(google_task, attributes_hash)
      return nil if (target_tasklist = tasklist).nil?

      debug("task: #{google_task.title}, attributes_hash: #{attributes_hash.pretty_inspect}", options[:debug])
      updated_task = Google::Apis::TasksV1::Task.new(**attributes_hash)
      debug("updated_task: #{updated_task.pretty_inspect}", options[:debug])
      tasks_service.patch_task(target_tasklist.id, external_task_id_for(google_task), updated_task)
      updated_task.to_h
    end

    def update_item(google_task, external_task)
      return nil if (target_tasklist = tasklist).nil?

      debug("existing_task: #{google_task.pretty_inspect}", options[:debug])
      updated_task_json = GoogleTasks::Task.from_external(external_task)
      updated_task = Google::Apis::TasksV1::Task.new(**updated_task_json)
      debug("updated_task: #{updated_task.pretty_inspect}", options[:debug])
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L510
      tasks_service.patch_task(target_tasklist.id, external_task_id_for(google_task), updated_task)
      updated_task.to_h
    end

    def prune
      return nil if (target_tasklist = tasklist).nil?

      tasks_service.clear_task(target_tasklist.id)
      puts "Deleted completed tasks from #{target_tasklist.title}" if options[:verbose]
    end

    def should_sync?(task_updated_at = nil)
      super
    end

    private

    # a helper method to fix bad syncs
    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L291
    def delete_all_tasks
      return if (target_tasklist = tasklist).nil?

      progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: items_to_sync.length)
      items_to_sync.each do |task|
        tasks_service.delete_task(target_tasklist.id, task.external_id)
        sleep 0.5
        progressbar.increment
      end
      puts "Deleted #{items_to_sync.count} tasks"
    end

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      30.minutes.to_i
    end

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L175
    def tasklist
      debug("called", options[:debug])
      return @tasklist if instance_variable_defined?(:@tasklist)

      tasklists = tasks_service.list_tasklists.items || []
      tasklist = tasklists.find { |list| list.title == options[:list] }
      if tasklist.nil?
        puts "Google Tasks list not configured or inaccessible: #{options[:list]}" unless options[:quiet]
        @authorized = false
      end

      @tasklist = tasklist
    end

    # In case a reclaim title is present, match the title
    def friendly_titles_match?(google_task, task)
      matcher = /\A(?<title>#{task.title.strip})\s*(?<addon>.*)\Z/i
      match_data = matcher.match(google_task.title)
      named_captures = match_data&.named_captures
      extracted_title = named_captures&.fetch("title", nil)
      google_title = extracted_title&.downcase&.strip
      google_title == task.title&.downcase&.strip
    end

    def external_task_id_for(google_task)
      task_id = google_task.try(:external_id) || google_task.try(:id)
      raise ArgumentError, "Google task is missing an external ID" if task_id.blank?

      task_id
    end

    # Returns RFC 3339 timestamp for 1 week ago, used to filter completed tasks
    # This allows syncing recently completed tasks while reducing API response size
    def completed_min_timestamp
      Chronic.parse("1 week ago").iso8601
    end
    memo_wise :completed_min_timestamp

    # Returns the last successful sync time from the logger, or nil if never synced
    def last_sync_time
      last_successful_sync_at
    end
    memo_wise :last_sync_time
  end
end
