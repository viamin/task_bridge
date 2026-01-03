# frozen_string_literal: true

require "google/apis/tasks_v1"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class Service < BaseCli
    include Debug
    include GlobalOptions

    attr_reader :tasks_service, :authorized

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def initialize
      @tasks_service = Google::Apis::TasksV1::TasksService.new
      @tasks_service.authorization = user_credentials_for(Google::Apis::TasksV1::AUTH_TASKS)
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

    desc "item_class", "The class of the item to sync"
    def item_class
      Google::Apis::TasksV1::Task
    end

    desc "friendly_name", "The friendly name of the service for use in tagging (and elsewhere)"
    def friendly_name
      "Google Tasks"
    end

    desc "sync_strategies", "Supported sync strategies for Google Tasks"
    def sync_strategies
      [:from_primary]
    end

    desc "items_to_sync", "Get all of the tasks to sync in options[:list]"
    def items_to_sync(*)
      debug("called", options[:debug])
      @items_to_sync ||= tasks_service.list_tasks(
        tasklist.id,
        max_results: 100,
        # Only include tasks completed within the last week (reduces response size)
        completed_min: completed_min_timestamp,
        # Only fetch tasks modified since last sync (if we have a previous sync time)
        updated_min: last_sync_time&.iso8601
      ).items
    end

    desc "add_item", "Add a new task to a given task list"
    def add_item(tasklist, external_task)
      return external_task.flag! if external_task.respond_to?(:estimated_minutes) && external_task.estimated_minutes.nil?

      google_task_json = GoogleTasks::Task.from_external(external_task)
      google_task = Google::Apis::TasksV1::Task.new(**google_task_json)
      debug("google_task: #{google_task.pretty_inspect}", options[:debug])
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L360
      tasks_service.insert_task(tasklist.id, google_task)
      google_task.to_h
    end

    desc "patch_item", "Patch an existing task in a task list"
    def patch_item(google_task, attributes_hash)
      debug("task: #{google_task.title}, attributes_hash: #{attributes_hash.pretty_inspect}", options[:debug])
      updated_task = Google::Apis::TasksV1::Task.new(**attributes_hash)
      debug("updated_task: #{updated_task.pretty_inspect}", options[:debug])
      tasks_service.patch(tasklist.id, google_task.id, updated_task)
      updated_task.to_h
    end

    desc "update_item", "Update an existing task in a task list"
    def update_item(tasklist, google_task, external_task)
      debug("existing_task: #{google_task.pretty_inspect}", options[:debug])
      updated_task_json = GoogleTasks::Task.from_external(external_task)
      updated_task = Google::Apis::TasksV1::Task.new(**updated_task_json)
      debug("updated_task: #{updated_task.pretty_inspect}", options[:debug])
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L510
      tasks_service.patch_task(tasklist.id, google_task.external_id, updated_task)
      updated_task.to_h
    end

    desc "prune", "Delete completed tasks"
    def prune
      tasks_service.clear_task(tasklist.id)
      puts "Deleted completed tasks from #{tasklist.title}" if options[:verbose]
    end

    desc "should_sync?", "Return boolean whether or not this service should sync. Time-based."
    def should_sync?(task_updated_at = nil)
      time_since_last_sync = options[:logger].last_synced(friendly_name, interval: task_updated_at.nil?)
      return true if time_since_last_sync.nil?

      if task_updated_at.present?
        time_since_last_sync < task_updated_at
      else
        time_since_last_sync > min_sync_interval
      end
    end

    private

    # a helper method to fix bad syncs
    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L291
    def delete_all_tasks
      progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: items_to_sync.length)
      items_to_sync.each do |task|
        tasks_service.delete_task(tasklist.id, task.external_id)
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
      tasklists = tasks_service.list_tasklists.items
      tasklist = tasklists.find { |list| list.title == options[:list] }
      raise "tasklist (#{options[:list]}) not found in #{tasklists}" if tasklist.nil?

      tasklist
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

    # Returns RFC 3339 timestamp for 1 week ago, used to filter completed tasks
    # This allows syncing recently completed tasks while reducing API response size
    def completed_min_timestamp
      Chronic.parse("1 week ago").iso8601
    end
    no_commands { memo_wise :completed_min_timestamp }

    # Returns the last successful sync time from the logger, or nil if never synced
    def last_sync_time
      options[:logger]&.last_synced(friendly_name)
    end
    no_commands { memo_wise :last_sync_time }
  end
end
