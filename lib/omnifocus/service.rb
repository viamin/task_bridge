require_relative "task"

module Omnifocus
  class Service
    SKIP_AGE = Chronic.parse("2 days ago")

    attr_reader :omnifocus

    def initialize(options)
      @options = options
      # Assumes you already have OmniFocus installed
      @omnifocus = Appscript.app.by_name("OmniFocus").default_document
    end

    def tasks_to_sync
      tagged_tasks
    end

    def add_task(task, options)
    end

    def update_task(existing_task, task, options)
    end

    private

    def tagged_tasks
      @tagged_tasks ||= begin
        target_tags = @options[:tags]
        tasks = []
        all_tags = omnifocus.flattened_tags.get
        matching_tags = all_tags.select { |tag| target_tags.include?(tag.name.get) }
        tagged_tasks = matching_tags.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten
        filtered_tasks(tagged_tasks).each do |task|
          tasks << Task.new(task, @options)
        end
        tasks
      end
    end

    # filters out duplicate and old tasks
    def filtered_tasks(tasks)
      tasks.compact.uniq(&:id_).delete_if do |task|
        completion_date = task.completion_date.get
        completion_date != :missing_value && completion_date < SKIP_AGE
      end
    end

    def today_tasks
      due_tasks.select do |task|
        task.due_date.to_date == Date.today
      end
    end

    def due_tasks
      tasks = []

      all_omnifocus_tasks.each do |task|
        due = task.due_date.get

        if due.is_a?(Time) && due.to_date > (Date.today - 1)
          tasks << Task.new(task, @options)
        end
      end

      tasks.sort_by(&:due_date)
    end

    def active_projects
      omnifocus.flattened_projects.get.select do |project|
        completion_date = project.completion_date.get
        completion_date == :missing_value
      end
    end

    # adapted from https://github.com/fredoliveira/forecast
    def all_omnifocus_subtasks(task)
      [task] + task.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }
    end

    def inbox_omnifocus_tasks
      omnifocus.inbox_tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }.flatten
    end

    def project_omnifocus_tasks(include_inactive = false)
      projects = include_inactive ? omnifocus.flattened_projects : active_projects
      projects.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten
    end

    def all_omnifocus_tasks(include_inactive = false)
      inbox_omnifocus_tasks + project_omnifocus_tasks(include_inactive)
    end
  end
end
