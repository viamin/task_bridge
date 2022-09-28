require "google/apis/tasks_v1"
require_relative "base_cli"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class Service < BaseCli
    DEBUG = false

    attr_reader :tasks_service, :options

    def initialize(options)
      @options = options
      @tasks_service = Google::Apis::TasksV1::TasksService.new
      @tasks_service.authorization = user_credentials_for(Google::Apis::TasksV1::AUTH_TASKS)
    end

    desc "sync_tasks", "Sync OmniFocus tasks to Google Tasks"
    def sync_tasks(omnifocus_tasks)
      existing_tasks = tasks_service.list_tasks(tasklist.id).items
      progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: omnifocus_tasks.length) if options[:verbose]
      omnifocus_tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| task_title_matches(t, task) })

          # if (existing_task = existing_tasks.find { |t| t.title == task.title })
          # update the existing task
          update_task(tasklist, existing_task, task, options)
        else
          # add a new task
          add_task(tasklist, task, options)
        end
        progressbar.log output if DEBUG
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{omnifocus_tasks.length} Omnifocus tasks to Google Tasks" if options[:verbose]
    end

    desc "add_task", "Add a new task to a given task list"
    def add_task(tasklist, omnifocus_task, options)
      google_task = task_from_omnifocus(omnifocus_task)
      tasks_service.insert_task(tasklist.id, google_task)
      google_task.to_h
    end

    desc "patch_task", "Update an existing task in a task list"
    def update_task(tasklist, google_task, omnifocus_task, options)
      updated_task = task_from_omnifocus(omnifocus_task)
      tasks_service.patch_task(tasklist.id, google_task.id, updated_task)
      updated_task.to_h
    end

    desc "prune_tasks", "Delete completed tasks"
    def prune_tasks
      tasks_service.clear_task(tasklist.id)
      puts "Deleted completed tasks from #{tasklist.title}" if options[:verbose]
    end

    private

    def tasklist
      @tasklist ||= tasks_service.list_tasklists.items.find { |list| list.title == options[:list] }
    end

    # @completed = args[:completed] if args.key?(:completed)
    # @deleted = args[:deleted] if args.key?(:deleted)
    # @due = args[:due] if args.key?(:due)
    # @etag = args[:etag] if args.key?(:etag)
    # @hidden = args[:hidden] if args.key?(:hidden)
    # @id = args[:id] if args.key?(:id)
    # @kind = args[:kind] if args.key?(:kind)
    # @links = args[:links] if args.key?(:links)
    # @notes = args[:notes] if args.key?(:notes)
    # @parent = args[:parent] if args.key?(:parent)
    # @position = args[:position] if args.key?(:position)
    # @self_link = args[:self_link] if args.key?(:self_link)
    # @status = args[:status] if args.key?(:status)
    # @title = args[:title] if args.key?(:title)
    # @updated = args[:updated] if args.key?(:updated)
    def task_from_omnifocus(omnifocus_task)
      task = {
        due: omnifocus_task.due_date&.to_datetime&.rfc3339,
        notes: omnifocus_task.note,
        status: omnifocus_task.completed ? "completed" : "needsAction",
        title: omnifocus_task.title + reclaim_title_addon(omnifocus_task)
      }.compact
      Google::Apis::TasksV1::Task.new(**task)
    end

    # generate a title addition that Reclaim can use to set additional settings
    # Form of TITLE ([DURATION] [DUE_DATE] [NOT_BEFORE] [TYPE])
    def reclaim_title_addon(omnifocus_task)
      duration = omnifocus_task.estimated_minutes.nil? ? "" : "for #{omnifocus_task.estimated_minutes} minutes"
      # due_date = omnifocus_task.due_date.nil? ? "" : "due #{omnifocus_task.due_date.to_datetime.strftime("%b %e")}"
      not_before = omnifocus_task.defer_date.nil? ? "" : "not before #{omnifocus_task.defer_date.to_datetime.strftime("%b %e")}"
      type = omnifocus_task.is_personal? ? "type personal" : ""
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
