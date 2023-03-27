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
    def initialize(options:)
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
      @items_to_sync ||= tasks_service.list_tasks(tasklist.id, max_results: 100).items
    end

    desc "add_item", "Add a new task to a given task list"
    def add_item(tasklist, external_task)
      return external_task.flag! if external_task.respond_to?(:estimated_minutes) && external_task.estimated_minutes.nil?

      google_task = Google::Apis::TasksV1::Task.new(**external_task.to_google)
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
    def update_item(tasklist, google_task, external_task, options)
      debug("existing_task: #{google_task.pretty_inspect}", options[:debug])
      updated_task = Google::Apis::TasksV1::Task.new(**external_task.to_google)
      debug("updated_task: #{updated_task.pretty_inspect}", options[:debug])
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
      progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: items_to_sync.length)
      items_to_sync.each do |task|
        tasks_service.delete_task(tasklist.id, task.id)
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
    no_commands { memo_wise :tasklist }

    # In case a reclaim title is present, match the title
    def friendly_titles_match?(google_task, task)
      matcher = /\A(?<title>#{task.title.strip})\s*(?<addon>.*)\Z/i
      google_title = matcher.match(google_task.title)&.named_captures&.fetch("title", nil)&.downcase&.strip
      google_title == task.title&.downcase&.strip
    end
  end
end
