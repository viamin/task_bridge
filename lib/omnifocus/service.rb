require_relative "task"

module Omnifocus
  class Service
    attr_reader :options, :omnifocus, :tasks

    def initialize(options)
      @options = options
      # Assumes you already have OmniFocus installed
      @omnifocus = Appscript.app.by_name("OmniFocus").default_document
      @tasks = task_to_sync(@options[:tags])
    end

    def sync(temp = nil)
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length, title: "Omnifocus tasks") if options[:verbose]
      tasks.each do |task|
        task.tags.filter { |tag| supported_sync_targets.include?(tag) }.each do |tag|
          if (existing_task = existing_tasks.find { |task| task.task_title.downcase == task.title.downcase })
          # update the existing task
          # primary_service.update_task(existing_task, task, options)
          elsif task.incomplete?
            # add a new task
            # primary_service.add_task(task, options)
          end
        end
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{tasks.length} Omnifocus tasks" if options[:verbose]
    end

    def tasks_to_sync(tags: nil, inbox: false)
      tasks = tagged_tasks(tags)
      tasks += inbox_tasks if inbox
      tasks
    end

    def existing_items
      @existing_items ||= task_to_sync(TaskBridge.supported_services)
    end

    def add_task(task, options = {})
      puts "Called #{self.class}##{__method__}" if options[:debug]
      if project(task) && !options[:pretend]
        project(task).make(new: :task, with_properties: task.properties)
      elsif !options[:pretend]
        new_task = omnifocus.make(new: :inbox_task, with_properties: task.properties)
        if new_task && !tags(task).empty?
          # add tags
          tags(task).each do |tag|
            omnifocus.add(tag, to: new_task.tags)
          end
          new_task
        end
      elsif options[:pretend] && options[:verbose]
        "Would have added #{task.title} to Omnifocus"
      end
    end

    def update_task(existing_task, task, options = {})
      puts "Called #{self.class}##{__method__}" if options[:debug]
      if task.completed? && existing_task.incomplete?
        existing_task.mark_complete unless options[:pretend]
        "Would have marked #{existing_task.title} complete in Omnifocus" if options[:pretend] && options[:verbose]
      elsif !options[:pretend]
        tags(task).each do |tag|
          add_tag(task: existing_task, tag: tag)
        end
      elsif options[:verbose]
        "Would have updated #{task.title} in Omnifocus"
      end
    end

    private

    def supported_sync_targets
      %w[GoogleTasks]
    end

    # Checks if a tag is already on a task, and if not adds it
    def add_tag(task:, tag:)
      omnifocus.add(tag, task.tags) unless task.tags.include?(tag.name.get)
    end

    # Checks that a project exists in Omnifocus, and if it does returns it
    def project(external_task)
      if external_task.project && (external_task.project.split(":").length > 0)
        parts = external_task.project.split(":")
        folder = omnifocus.flattened_folders[parts.first]
        project = folder.projects[parts.last]
      elsif external_task.project
        project = omnifocus.flattened_projects[external_task.project]
      end
      project.get
      project
    rescue
      puts "The project #{external_task.project} does not exist in Omnifocus" if options[:verbose]
      nil
    end

    # Checks that a tag exists in Omnifocus and if it does, returns it
    def tag(name)
      tag = omnifocus.flattened_tags[name]
      tag.get
      tag
    rescue
      puts "The tag #{name} does not exist in Omnifocus" if options[:verbose]
      nil
    end

    # Maps a list of tag names on a task to Omnifocus tags
    def tags(task)
      task.tags.map { |tag| tag(tag) }.compact
    end

    def inbox_titles
      @inbox_titles ||= inbox_tasks.map(&:title)
    end

    def inbox_tasks
      @inbox_tasks ||= begin
        tasks = []
        inbox_tasks = omnifocus.inbox_tasks.get.map { |t| all_omnifocus_subtasks(t) }.flatten
        inbox_tasks.compact.uniq(&:id_).each do |task|
          tasks << Task.new(task, @options)
        end
        tasks
      end
    end

    def tagged_tasks(tags = nil)
      @tagged_tasks ||= begin
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
