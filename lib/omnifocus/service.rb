# frozen_string_literal: true

require_relative "task"

module Omnifocus
  class Service
    prepend MemoWise

    attr_reader :options, :omnifocus

    def initialize(options)
      @options = options
      # Assumes you already have OmniFocus installed
      @omnifocus = Appscript.app.by_name("OmniFocus").default_document
    end

    # Sync primary service tasks to Omnifocus
    def sync_from(primary_service)
      tasks = primary_service.tasks_to_sync(tags: ["Omnifocus"])
      existing_tasks = tasks_to_sync(tags: options[:tags], inbox: true)
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length,
                                         title: "Omnifocus Tasks")
      end
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| task_title_matches(t, task) })
          update_task(existing_task, task)
        else
          add_task(task) unless task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{tasks.length} #{options[:primary]} items to Omnifocus" unless options[:quiet]
    end

    def tasks_to_sync(tags: nil, project: nil, inbox: false)
      omnifocus_tasks = []
      tagged_tasks = tagged_tasks(tags)
      project_tasks = project_tasks(project)
      tagged_project_tasks = if tags && project
        tagged_tasks & project_tasks
      else
        tagged_tasks | project_tasks
      end
      omnifocus_tasks += tagged_project_tasks
      omnifocus_tasks += inbox_tasks if inbox
      tasks = omnifocus_tasks.map { |task| Task.new(task, @options) }
      # remove subtasks from the list
      tasks_with_subtasks = tasks.select { |task| task.subtask_count.positive? }
      subtask_ids = tasks_with_subtasks.map(&:subtasks).flatten.map(&:id)
      tasks.delete_if { |task| subtask_ids.include?(task.id) }
    end
    memo_wise :tasks_to_sync

    def add_task(external_task, options = {}, parent_object = nil)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      task_type = :task
      if parent_object.nil?
        if project(external_task)
          parent_object = project(external_task)
        else
          parent_object = omnifocus
          task_type = :inbox_task
        end
      end
      if !options[:pretend]
        new_task = parent_object.make(new: task_type, with_properties: external_task.to_omnifocus)
        handle_subtasks(new_task, external_task)
      elsif options[:pretend] && options[:verbose]
        "Would have added #{external_task.title} to Omnifocus"
      end
      return unless new_task && !tags(external_task).empty? && !options[:pretend]

      tags(external_task).each do |tag|
        add_tag(tag:, task: new_task)
      end
      new_task
    end

    def update_task(omnifocus_task, external_task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      if options[:max_age_timestamp] && external_task.updated_at && (external_task.updated_at < options[:max_age_timestamp])
        "Last modified more than #{options[:max_age]} ago - skipping #{external_task.title}"
      elsif external_task.completed? && omnifocus_task.incomplete?
        if options[:pretend]
          "Would have marked #{omnifocus_task.title} complete in Omnifocus"
        else
          omnifocus_task.mark_complete unless options[:pretend]
          handle_subtasks(omnifocus_task, external_task)
        end
      elsif !options[:pretend] && !external_task.completed? # don't add tags to completed tasks
        tags(external_task).each do |tag|
          add_tag(tag:, task: omnifocus_task)
        end
        if external_task.project && (external_task.project != omnifocus_task.project)
          # update the project via assigned_container property
          omnifocus_task.original_task.assigned_container.set(project(external_task))
        end
        handle_subtasks(omnifocus_task, external_task)
        external_task
      elsif options[:pretend]
        "Would have updated #{external_task.title} in Omnifocus"
      end
    end

    private

    # create or update subtasks on a task
    def handle_subtasks(omnifocus_task, external_task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      return unless external_task.respond_to?(:subtask_count) && external_task.subtask_count.positive?

      original_task = if omnifocus_task.is_a?(Omnifocus::Task)
        omnifocus_task.original_task
      else
        omnifocus_task
      end
      omnifocus_subtasks = original_task.tasks.get
      external_task.subtasks.each do |subtask|
        if (existing_task = omnifocus_subtasks.find { |omnifocus_subtask| task_title_matches(omnifocus_subtask, subtask) })
          update_task(existing_task, subtask)
        else
          add_task(subtask, options, original_task) unless subtask.completed?
          "Creating subtask #{subtask.title} of task #{external_task.title} in Omnifocus"
        end
      end
    end

    def task_title_matches(task, external_task)
      puts "Called #{self.class}##{__method__} with task: #{task}, external_task: #{external_task}" if options[:debug]
      if task.is_a?(Appscript::Reference)
        task.name.get.downcase.strip == external_task.title.downcase.strip
      else
        task.title.downcase.strip == external_task.title.downcase.strip
      end
    end

    # Checks if a tag is already on a task, and if not adds it
    def add_tag(task:, tag:)
      puts "Called #{self.class}##{__method__} with task: #{task}, tag: #{tag}" if options[:debug]
      target_task = if task.instance_of?(Omnifocus::Task)
        puts "Finding native Omnifocus task for #{task.title}" if options[:debug]
        found_task = (inbox_tasks + tagged_tasks(task.tags)).find { |t| t.name.get == task.task_title }
        puts "Found task: #{found_task}" if options[:debug] && found_task
        found_task
      else
        puts "#{self.class}##{__method__} was called with a native Omnifocus task" if options[:debug]
        task
      end
      if target_task.tags.get.map(&:name).map(&:get).include?(tag.name.get)
        puts "Task (#{target_task.name.get}) already has tag #{tag.name.get}" if options[:debug]
      else
        puts "Adding tag #{tag.name.get} to task \"#{target_task.name.get}\"" if options[:debug]
        omnifocus.add(tag, to: target_task.tags)
      end
    end

    # Checks that a project exists in Omnifocus, and if it does returns it
    # Alternately, send just the project string and get back the project
    def project(external_task, project_string = nil)
      puts "Called #{self.class}##{__method__} Looking for project: #{external_task.project}" if options[:debug]
      project_structure = external_task&.project || project_string
      if project_structure && (project_structure.split(":").length > 1)
        parts = project_structure.split(":")
        folder = omnifocus.flattened_folders[parts.first]
        project = folder.projects[parts.last]
      elsif project_structure
        project = omnifocus.flattened_projects[project_structure]
      end
      project.get
      project
    rescue StandardError
      puts "The project #{project_structure} does not exist in Omnifocus" if options[:verbose]
      nil
    end
    memo_wise :project

    # Checks that a tag exists in Omnifocus and if it does, returns it
    def tag(name)
      tag = omnifocus.flattened_tags[name]
      tag.get
    rescue StandardError
      puts "The tag #{name} does not exist in Omnifocus" if options[:verbose]
      nil
    end
    memo_wise :tag

    # Maps a list of tag names on an Omnifocus::Task to Omnifocus tags
    def tags(task)
      task.tags.filter_map { |tag| tag(tag) }
    end
    memo_wise :tags

    def inbox_titles
      @inbox_titles ||= inbox_tasks.map(&:title)
    end

    def inbox_tasks
      @inbox_tasks ||= begin
        inbox_tasks = omnifocus.inbox_tasks.get.map { |t| all_omnifocus_subtasks(t) }.flatten
        inbox_tasks.compact.uniq(&:id_)
      end
    end

    def project_tasks(project_name = nil)
      return [] if project_name.nil?

      project = project(nil, project_name)
      project.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }.flatten.compact.uniq(&:id_)
    end

    def tagged_tasks(tags = nil)
      return [] if tags.nil?

      matching_tags = omnifocus.flattened_tags.get.select { |tag| tags.include?(tag.name.get) }
      matching_tags.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten.compact.uniq(&:id_)
    end
    memo_wise :tagged_tasks

    # adapted from https://github.com/fredoliveira/forecast
    def all_omnifocus_subtasks(task)
      [task] + task.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }
    end
  end
end
