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
    end

    desc "sync", "Sync OmniFocus tasks to Google Tasks"
    def sync(primary_service)
      tasks = primary_service.tasks_to_sync
      existing_tasks = tasks_service.list_tasks(tasklist.id).items
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length, title: "Google Tasks") if options[:verbose] || options[:debug]
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| task_title_matches(t, task) })
          # update the existing task
          update_task(tasklist, existing_task, task, options)
        else
          # add a new task
          add_task(tasklist, task, options)
        end
        progressbar.log output if options[:debug]
        progressbar.increment if options[:verbose] || options[:debug]
      end
      puts "Synced #{tasks.length} #{options[:primary]} tasks to Google Tasks" if options[:verbose]
    end

    desc "add_task", "Add a new task to a given task list"
    def add_task(tasklist, omnifocus_task, options)
      google_task = task_from_omnifocus(omnifocus_task)
      puts "#{self.class}##{__method__}: #{google_task.pretty_inspect}" if options[:debug]
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/service.rb#L360
      tasks_service.insert_task(tasklist.id, google_task)
      google_task.to_h
    end

    desc "update_task", "Update an existing task in a task list"
    def update_task(tasklist, google_task, omnifocus_task, options)
      puts "#{self.class}##{__method__} existing_task: #{google_task.pretty_inspect}" if options[:debug]
      updated_task = task_from_omnifocus(omnifocus_task)
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

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def task_from_omnifocus(omnifocus_task)
      task = {
        completed: omnifocus_task.completion_date&.to_datetime&.rfc3339,
        due: omnifocus_task.due_date&.to_datetime&.rfc3339,
        notes: omnifocus_task.note,
        status: omnifocus_task.completed ? "completed" : "needsAction",
        title: omnifocus_task.title + reclaim_title_addon(omnifocus_task)
      }.compact
      Google::Apis::TasksV1::Task.new(**task)
    end

    # generate a title addition that Reclaim can use to set additional settings
    # Form of TITLE ([DURATION] [DUE_DATE] [NOT_BEFORE] [TYPE])
    # refer to https://help.reclaim.ai/en/articles/4293078-use-natural-language-in-the-google-task-integration
    def reclaim_title_addon(omnifocus_task)
      duration = omnifocus_task.estimated_minutes.nil? ? "" : "for #{omnifocus_task.estimated_minutes} minutes"
      not_before = omnifocus_task.defer_date.nil? ? "" : "not before #{omnifocus_task.defer_date.to_datetime.strftime("%b %e")}"
      type = omnifocus_task.is_personal? ? "type personal" : ""
      # due_date = omnifocus_task.due_date.nil? ? "" : "due #{omnifocus_task.due_date.to_datetime.strftime("%b %e %l %p")}"
      # Due date doesn't seem to work correctly, but is supported natively by Google tasks, so use that
      addon_string = "#{type} #{duration} #{not_before}".squeeze(" ").strip
      addon_string.empty? ? "" : " (#{addon_string})"
    end

    def task_title_matches(google_task, omnifocus_task)
      matcher = /\A(?<title>.+)\s*(?<addon>.*)\Z/i
      google_title = matcher.match(google_task.title).named_captures.fetch("title", nil)&.downcase&.strip
      google_title == omnifocus_task.title&.downcase&.strip
    end
  end
end
