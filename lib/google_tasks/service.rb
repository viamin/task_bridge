require "google/apis/tasks_v1"
require_relative "base_cli"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class Service < BaseCli
    attr_reader :tasks_service

    def initialize
      @tasks_service = Google::Apis::TasksV1::TasksService.new
      @tasks_service.authorization = user_credentials_for(Google::Apis::TasksV1::AUTH_TASKS)
    end

    desc "add_task", "Add a new task to a given task list"
    def add_task(tasklist, omnifocus_task, silent = false)
      google_task = task_from_omnifocus(omnifocus_task)
      tasks_service.insert_task(tasklist.id, google_task)
      puts google_task.to_h unless silent
    end

    private

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
        status: "needsAction",
        title: omnifocus_task.title
      }.compact
      Google::Apis::TasksV1::Task.new(**task)
    end
  end
end
