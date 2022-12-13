# frozen_string_literal: true

require "google/apis/tasks_v1"
require_relative "base_cli"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class Service < BaseCli
    attr_reader :tasks_service, :options

    def initialize(options)
      @options = options
      @tasks_service = Google::Apis::TasksV1::TasksService.new
      @tasks_service.authorization = user_credentials_for(Google::Apis::TasksV1::AUTH_TASKS)
    rescue StandardError
      # If authentication fails, skip the service
      nil
    end

    desc "sync_from_primary", "Sync from primary service tasks to Google Tasks"
    def sync_from_primary(primary_service)
      tasks = primary_service.tasks_to_sync(tags: ["Google Tasks"])
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length,
                                         title: "Google Tasks")
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
    end

    desc "tasks_to_sync", "Get all of the tasks to sync in options[:list]"
    def tasks_to_sync(*)
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

    private

    def tasklist
      @tasklist ||= tasks_service.list_tasklists.items.find { |list| list.title == options[:list] }
    end

    # In case a reclaim title is present, match the title
    def friendly_titles_match?(google_task, task)
      matcher = /\A(?<title>.+)\s*(?<addon>.*)\Z/i
      google_title = matcher.match(google_task.title).named_captures.fetch("title", nil)&.downcase&.strip
      google_title == task.title&.downcase&.strip
    end
  end
end
