require_relative "task"

module Omnifocus
  class Service
    attr_reader :omnifocus

    def initialize(options)
      @options = options
      # Assumes you already have OmniFocus installed
      @omnifocus = Appscript.app.by_name("OmniFocus").default_document
    end

    def tasks_to_sync
      tagged_tasks
    end

    def add_task(issue, options = {})
      project = omnifocus.flattened_projects[issue.project] if issue.project
      task = if defined?(project)
        project.make(new: :task, with_properties: issue.properties)
      else
        omnifocus.make(new: :inbox_task, with_properties: issue.properties)
      end
      if task
        # add tags
        tags(issue).each do |tag|
          omnifocus.add(tag, to: task.tags)
        end
        task
      end
    end

    # currently only used to mark closed issues as done
    def update_task(existing_task, issue, options = {})
      if issue.closed? && existing_task.incomplete?
        existing_task.mark_complete
      end
    end

    private

    def tags(issue)
      issue.tags.map do |tag|
        omnifocus.flattened_tags[tag]
      end
    end

    def tagged_tasks
      @tagged_tasks ||= begin
        target_tags = @options[:tags]
        tasks = []
        all_tags = omnifocus.flattened_tags.get
        matching_tags = all_tags.select { |tag| target_tags.include?(tag.name.get) }
        tagged_tasks = matching_tags.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten
        tagged_tasks.compact.uniq(&:id_).each do |task|
          tasks << Task.new(task, @options)
        end
        tasks
      end
    end

    # adapted from https://github.com/fredoliveira/forecast
    def all_omnifocus_subtasks(task)
      [task] + task.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }
    end
  end
end
