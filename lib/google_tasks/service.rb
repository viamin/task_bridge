# frozen_string_literal: true

require "google/apis/tasks_v1"
require_relative "base_cli"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class Service < BaseCli
    include Debug
    prepend MemoWise

    attr_reader :tasks_service, :options, :authorized

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def initialize(options)
      @options = options
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

    desc "friendly_name", "The friendly name of the service for use in tagging (and elsewhere)"
    def friendly_name
      "Google Tasks"
    end

    desc "sync_from_primary", "Sync from primary service tasks to Google Tasks"
    def sync_from_primary(primary_service)
      tasks = primary_service.tasks_to_sync(tags: [friendly_name])
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length,
                                         title: friendly_name)
      end
      tasks.each do |task|
        # next if options[:max_age] && task.updated_at && (task.updated_at < options[:max_age])

        output = if (existing_task = tasks_to_sync.find { |t| friendly_titles_match?(t, task) })
          update_task(tasklist, existing_task, task, options)
        else
          add_task(tasklist, task, options) unless task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{tasks.length} #{options[:primary]} tasks to Google Tasks" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: tasks.length }.stringify_keys
    end

    desc "tasks_to_sync", "Get all of the tasks to sync in options[:list]"
    def tasks_to_sync(*)
      debug("called") if options[:debug]
      @tasks_to_sync ||= tasks_service.list_tasks(tasklist.id, max_results: 100).items
    end

    desc "add_task", "Add a new task to a given task list"
    def add_task(tasklist, external_task, options)
      return external_task.flag! if external_task.respond_to?(:estimated_minutes) && external_task.estimated_minutes.nil?

      google_task = Google::Apis::TasksV1::Task.new(**external_task.to_google)
      puts "#{self.class}##{__method__}: #{google_task.pretty_inspect}" if options[:debug]
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L360
      tasks_service.insert_task(tasklist.id, google_task)
      google_task.to_h
    end

    desc "update_task", "Update an existing task in a task list"
    def update_task(tasklist, google_task, external_task, options)
      puts "#{self.class}##{__method__} existing_task: #{google_task.pretty_inspect}" if options[:debug]
      updated_task = Google::Apis::TasksV1::Task.new(**external_task.to_google)
      puts "#{self.class}##{__method__} updated_task: #{updated_task.pretty_inspect}" if options[:debug]
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L510
      tasks_service.patch_task(tasklist.id, google_task.id, updated_task)
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
      progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: tasks_to_sync.length)
      tasks_to_sync.each do |task|
        tasks_service.delete_task(tasklist.id, task.id)
        sleep 0.5
        progressbar.increment
      end
      puts "Deleted #{tasks_to_sync.count} tasks"
    end

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      30.minutes.to_i
    end

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L175
    def tasklist
      debug("called") if options[:debug]
      tasklists = tasks_service.list_tasklists.items
      tasklist = tasklists.find { |list| list.title == options[:list] }
      raise "tasklist (#{options[:list]}) not found in #{tasklists}" if tasklist.nil?

      tasklist
    end
    no_commands { memo_wise :tasklist }

    # In case a reclaim title is present, match the title
    def friendly_titles_match?(google_task, task)
      matcher = /\A(?<title>.+)\s*(?<addon>.*)\Z/i
      google_title = matcher.match(google_task.title).named_captures.fetch("title", nil)&.downcase&.strip
      google_title == task.title&.downcase&.strip
    end
  end
end
