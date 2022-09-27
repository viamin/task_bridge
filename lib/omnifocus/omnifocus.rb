module Omnifocus
  class Omnifocus
    SKIP_AGE = Chronic.parse("2 days ago")

    attr_reader :omnifocus

    def initialize
      # Assumes you already have OmniFocus installed
      @omnifocus = Appscript.app.by_name("OmniFocus").default_document
    end

    def sync_tasks
      tags = [
        "Work",
        "Today",
        "Tomorrow",
        "This Week",
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
        "Next Week",
        "This Month",
        "Next Month",
        "01 - January",
        "02 - February",
        "03 - March",
        "04 - April",
        "05 - May",
        "06 - June",
        "07 - July",
        "08 - August",
        "09 - September",
        "10 - October",
        "11 - November",
        "12 - December"
      ]
      tagged_tasks(tags)
    end

    private

    def tagged_tasks(target_tags)
      tasks = []
      tags = omnifocus.flattened_tags.get
      matching_tags = tags.select { |tag| target_tags.include?(tag.name.get) }
      tagged_tasks = matching_tags.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten
      filtered_tasks(tagged_tasks).each do |task|
        tasks << Task.new(task)
      end
      tasks
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
          tasks << Task.new(task, due)
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
