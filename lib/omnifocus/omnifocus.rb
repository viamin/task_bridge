module Omnifocus
  class Omnifocus
    attr_reader :omnifocus

    def initialize
      # Assumes you already have OmniFocus installed
      @omnifocus = Appscript.app.by_name("OmniFocus").default_document
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
          tasks << Task.new(task, due)
        end
      end

      tasks.sort_by(&:due_date)
    end

    private

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
      omnifocus.inbox_omnifocus_tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }.flatten
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
