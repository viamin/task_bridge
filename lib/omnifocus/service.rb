# frozen_string_literal: true

require_relative "task"
require_relative "../base/service"

module Omnifocus
  class Service < Base::Service
    attr_reader :omnifocus_app

    def initialize(options: {})
      super
      # Assumes you already have OmniFocus installed
      @omnifocus_app = Appscript.app.by_name(friendly_name).default_document
    end

    def item_class
      Task
    end

    def friendly_name
      "Omnifocus"
    end

    # Sync primary service tasks to Omnifocus
    def sync_from_primary(primary_service)
      tasks = primary_service.items_to_sync(tags: [friendly_name])
      existing_tasks = items_to_sync(tags: options[:tags], inbox: true)
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length,
                                         title: "Omnifocus Tasks")
      end
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| friendly_titles_match?(t, task) })
          update_item(existing_task, task)
        else
          add_item(task) unless task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{tasks.length} #{options[:primary]} items to Omnifocus" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: tasks.length }.stringify_keys
    end

    def items_to_sync(tags: nil, projects: nil, folder: nil, inbox: false, incomplete_only: false)
      tagged_tasks = tagged_tasks(tags, incomplete_only:)
      project_tasks = project_tasks(projects, incomplete_only:)
      folder_tasks = folder_tasks(folder, incomplete_only:)
      tagged_project_tasks = if tags && projects
        tagged_tasks & project_tasks
      elsif tags && folder
        tagged_tasks & folder_tasks
      else
        tagged_tasks | project_tasks | folder_tasks
      end
      omnifocus_tasks = []
      omnifocus_tasks += tagged_project_tasks
      omnifocus_tasks += inbox_tasks if inbox
      tasks = omnifocus_tasks.map { |task| Task.new(omnifocus_task: task, options: @options) }
      # remove subtasks from the list
      tasks_with_subtasks = tasks.select { |task| task.subtask_count.positive? }
      subtask_ids = tasks_with_subtasks.map(&:subtasks).flatten.map(&:id)
      tasks.delete_if { |task| subtask_ids.include?(task.id) }
    end
    memo_wise :items_to_sync

    def add_item(external_task, options = {}, parent_object = nil)
      debug("external_task: #{external_task}, parent_object: #{parent_object}", options[:debug])
      task_type = :task
      if parent_object.nil?
        if project(external_task).is_a?(Appscript::Reference)
          parent_object = project(external_task)
        else
          parent_object = omnifocus_app
          task_type = :inbox_task
        end
      elsif parent_object.is_a?(Omnifocus::Task)
        debug("parent_object: #{parent_object}", options[:debug])
        parent_object = parent_object.original_task
      end
      if !options[:pretend]
        new_task = parent_object.make(new: task_type, with_properties: external_task.to_omnifocus)
      elsif options[:pretend] && options[:verbose]
        "Would have added #{external_task.title} to Omnifocus"
      end
      return unless new_task && !tags(external_task).empty? && !options[:pretend]

      tags(external_task).each do |tag|
        add_tag(tag:, task: new_task)
      end
      handle_subtasks(Omnifocus::Task.new(omnifocus_task: new_task, options:), external_task)
      new_task
    end

    def update_item(omnifocus_task, external_task)
      debug("omnifocus_task: #{omnifocus_task}, external_task: #{external_task}", options[:debug])
      if options[:max_age_timestamp] && external_task.updated_at && (external_task.updated_at < options[:max_age_timestamp])
        "Last modified more than #{options[:max_age]} ago - skipping #{external_task.title}"
      elsif external_task.completed? && omnifocus_task.incomplete?
        debug("Complete state doesn't match", options[:debug])
        if options[:pretend]
          "Would have marked #{omnifocus_task.title} complete in Omnifocus"
        else
          omnifocus_task.mark_complete unless options[:pretend]
          handle_subtasks(omnifocus_task, external_task)
        end
      elsif !options[:pretend] && !external_task.completed? # don't add tags to completed tasks
        debug("Tagging omnifocus_task from (#{external_task.title})", options[:debug])
        tags(external_task).each do |tag|
          add_tag(tag:, task: omnifocus_task)
        end
        if external_task.project && !task_projects_match(external_task, omnifocus_task)
          debug("Projects don't match: (#{external_task.provider})#{external_task} <=> (Omnifocus)#{omnifocus_task}", options[:debug])
          # update the project via assigned_container property
          updated_project = project(nil, external_task.project)
          debug("updated_project: #{updated_project}", options[:debug])
          task_to_update = if omnifocus_task.is_a?(Appscript::Reference)
            omnifocus_task
          else
            omnifocus_task.original_task
          end
          task_to_update.assigned_container.set(updated_project) if updated_project
        end
        handle_subtasks(omnifocus_task, external_task)
        external_task
      elsif options[:pretend]
        "Would have updated #{external_task.title} in Omnifocus"
      end
    end

    def inbox_titles
      @inbox_titles ||= inbox_tasks.map(&:title)
    end

    def inbox_tasks
      debug("called", options[:debug])
      inbox_tasks = omnifocus_app.inbox_tasks.get.map { |t| all_omnifocus_subtasks(t) }.flatten
      inbox_tasks.compact.uniq(&:id_)
    end
    memo_wise :inbox_tasks

    def folder_tasks(folder_name = nil, incomplete_only: false)
      debug("folder_name: #{folder_name}", options[:debug])
      return [] if folder_name.nil?

      folder = folder(folder_name)
      folder_projects = folder.flattened_projects.get
      all_tasks_in_container(folder_projects, incomplete_only:)
    end
    memo_wise :folder_tasks

    def project_tasks(project_names = nil, incomplete_only: false)
      debug("project_names: #{project_names}", options[:debug])
      return [] if project_names.nil?

      project_names.split(",").map do |project_name|
        project = project(nil, project_name)
        all_tasks_in_container(project, incomplete_only:)
      end.flatten
    end
    memo_wise :project_tasks

    def tagged_tasks(tags = nil, incomplete_only: false)
      debug("tags: #{tags}", options[:debug])
      return [] if tags.nil?

      matching_tags = omnifocus_app.flattened_tags.get.select { |tag| tags.include?(tag.name.get) }
      all_tasks_in_container(matching_tags, incomplete_only:)
      # matching_tags.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten.compact.uniq(&:id_)
    end
    memo_wise :tagged_tasks

    private

    def min_sync_interval
      15.minutes.to_i
    end

    # create or update subtasks on a task
    def handle_subtasks(omnifocus_task, external_task)
      debug("omnifocus_task: #{omnifocus_task}, external_task: #{external_task}", options[:debug])
      return unless external_task.respond_to?(:subtask_count) && external_task.subtask_count.positive?

      omnifocus_subtasks = omnifocus_task.subtasks
      external_task.subtasks.each do |subtask|
        if (existing_subtask = omnifocus_subtasks.find { |omnifocus_subtask| friendly_titles_match?(omnifocus_subtask, subtask) })
          update_item(existing_subtask, subtask)
          "Updated subtask #{subtask.title} of task #{external_task.title} in Omnifocus"
        else
          add_item(subtask, options, omnifocus_task) unless subtask.completed?
          "Created subtask #{subtask.title} of task #{external_task.title} in Omnifocus"
        end
      end
    end

    def task_projects_match(task, external_task)
      debug("task: #{task}, external_task: #{external_task}", options[:debug])
      project_name = if task.is_a?(Appscript::Reference)
        task.containing_project.get.name.get
      else
        task.project
      end
      project_name = project_name.split(":").last if project_name.split(":").length > 1
      external_project_name = if external_task.is_a?(Appscript::Reference)
        external_task.containing_project.get.name.get
      else
        external_task.project
      end
      external_project_name = external_project_name.split(":").last if external_project_name.split(":").length > 1
      debug("project_name: #{project_name}, external_project_name: #{external_project_name}", options[:debug])
      project_name.strip == external_project_name.strip
    end

    def friendly_titles_match?(task, external_task)
      debug("task: #{task}, external_task: #{external_task}", options[:debug])
      if task.is_a?(Appscript::Reference)
        task.name.get.downcase.strip == external_task.title.downcase.strip
      else
        task.title.downcase.strip == external_task.title.downcase.strip
      end
    end

    # Checks if a tag is already on a task, and if not adds it
    def add_tag(task:, tag:)
      debug("task: #{task}, tag: #{tag}", options[:debug])
      target_task = if task.instance_of?(Omnifocus::Task)
        debug("Finding native Omnifocus task for #{task.title}", options[:debug])
        found_task = (inbox_tasks + tagged_tasks(task.tags)).find { |t| t.name.get == task.friendly_title }
        debug("Found task: #{found_task}", options[:debug]) if found_task
        found_task
      else
        debug("called with a native Omnifocus task", options[:debug])
        task
      end
      if target_task.tags.get.map(&:name).map(&:get).include?(tag.name.get)
        debug("Task (#{target_task.name.get}) already has tag #{tag.name.get}", options[:debug])
      else
        debug("Adding tag #{tag.name.get} to task \"#{target_task.name.get}\"", options[:debug])
        omnifocus_app.add(tag, to: target_task.tags)
      end
    end

    # Looks for an Omnifocus folder matching the folder_name
    def folder(folder_name)
      debug("folder_name: #{folder_name}", options[:debug])
      omnifocus_app.flattened_folders[folder_name].get
    rescue StandardError
      puts "The folder #{folder_name} could not be found in Omnifocus" if options[:verbose]
      nil
    end

    # Checks that a project exists in Omnifocus, and if it does returns it
    # Alternately, send just the project string and get back the project
    def project(external_task, project_string = nil)
      debug("external_task: #{external_task}, project_string: #{project_string}", options[:debug])
      project_structure = external_task.nil? ? project_string : external_task.project
      if project_structure && (project_structure.split(":").length > 1)
        debug("Splitting project_structure: #{project_structure}", options[:debug])
        parts = project_structure.split(":")
        folder = folder(parts.first)
        project = folder.projects[parts.last]
      elsif project_structure
        debug("Using project_structure: #{project_structure}", options[:debug])
        # First, try to get a folder and sub-projects of that folder
        folder = folder(project_structure)
        if folder
          project = folder.flattened_projects[project_structure].get
        else
          # If a folder project can't be found, check for any matching project
          project ||= omnifocus_app.flattened_projects[project_structure]
        end
        debug("project: #{project.name.get}", options[:debug])
      end
      debug("project: #{project}", options[:debug])
      project.get
      project
    rescue StandardError
      puts "The project #{project_structure} does not exist in Omnifocus" if options[:verbose]
      nil
    end
    memo_wise :project

    # Checks that a tag exists in Omnifocus and if it does, returns it
    def tag(name)
      tag = omnifocus_app.flattened_tags[name]
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

    def all_tasks_in_container(container, incomplete_only: false)
      tasks = case container
              when Array
                container.map { |subcontainer| subcontainer.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }.flatten.compact.uniq(&:id_) }.flatten
              when Appscript::Reference
                container.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }.flatten.compact.uniq(&:id_)
      end
      return tasks unless incomplete_only

      tasks.reject { |task| task.completed.get }
    end
    memo_wise :all_tasks_in_container

    # adapted from https://github.com/fredoliveira/forecast
    def all_omnifocus_subtasks(task)
      [task] + task.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }
    end
  end
end
