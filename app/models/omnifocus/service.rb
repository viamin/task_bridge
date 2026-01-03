# frozen_string_literal: true

module Omnifocus
  class Service < Base::Service
    attr_reader :omnifocus_app, :authorized

    def initialize
      super
      # Assumes you already have OmniFocus installed
      @omnifocus_app = Appscript.app.by_name(friendly_name).default_document
      @authorized = true
    rescue => e
      # If OmniFocus app is not available, skip the service
      puts "OmniFocus initialization failed: #{e.message}" unless options[:quiet]
      @omnifocus_app = nil
      @authorized = false
    end

    def item_class
      Task
    end

    def friendly_name
      "Omnifocus"
    end

    def sync_strategies
      [:from_primary]
    end

    def items_to_sync(tags: options[:tags], inbox: true, only_modified_dates: false)
      omnifocus_tasks = tagged_tasks(tags)
      omnifocus_tasks += inbox_tasks if inbox
      tasks = omnifocus_tasks.map do |external_task|
        task = Task.find_or_initialize_by(external_id: external_task.id_.get)
        task.omnifocus_task = external_task
        task.read_original(only_modified_dates:)
      end
      # Filter out stale references (tasks deleted while iterating)
      tasks = tasks.reject { |task| task.external_id.nil? }
      # remove sub_items from the list
      # TODO: why tho?
      # tasks_with_sub_items = tasks.select { |task| task.sub_item_count.positive? }
      # sub_item_ids = tasks_with_sub_items.map(&:sub_items).flatten.map(&:external_id)
      # tasks.delete_if { |task| sub_item_ids.include?(task.external_id) }
    end

    def add_item(external_task, parent_object = nil)
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
        new_task = parent_object.make(new: task_type, with_properties: Task.from_external(external_task))
        new_task_id = new_task.id_.get
        update_sync_data(external_task, new_task_id, Task.url(new_task_id))
      elsif options[:pretend] && options[:verbose]
        "Would have added #{external_task.title} to Omnifocus"
      end
      return unless new_task && !tags(external_task).empty? && !options[:pretend]

      tags(external_task).each do |tag|
        add_tag(tag:, task: new_task)
      end
      handle_sub_items(Omnifocus::Task.new(omnifocus_task: new_task), external_task)
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
          handle_sub_items(omnifocus_task, external_task)
        end
      elsif !options[:pretend] && !external_task.completed? # don't add tags to completed tasks
        debug("Tagging omnifocus_task from (#{external_task.title})", options[:debug])
        tags(external_task).each do |tag|
          add_tag(tag:, task: omnifocus_task)
        end
        # Detect if this was a title match vs ID match
        # Title match: external_task doesn't have our sync ID
        matched_by_title = external_task.try(:omnifocus_id).blank?
        # Only move projects for ID-matched items (reliable link)
        # Title matches are not reliable enough to warrant moving tasks between projects
        if !matched_by_title && external_task.try(:project) && !task_projects_match(external_task, omnifocus_task)
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
        handle_sub_items(omnifocus_task, external_task)
        omnifocus_task_id = omnifocus_task.id_.get
        # Add sync ID so future syncs use ID matching instead of title matching
        if matched_by_title || options[:update_ids_for_existing]
          update_sync_data(external_task, omnifocus_task_id, Task.url(omnifocus_task_id))
        end
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
      inbox_tasks = omnifocus_app.inbox_tasks.get.map { |t| all_omnifocus_sub_items(t) }.flatten
      inbox_tasks.compact.uniq(&:id_)
    end

    def tagged_tasks(tags = nil, incomplete_only: false)
      debug("tags: #{tags}", options[:debug])
      return [] if tags.blank?

      # Use direct AppleScript reference lookup instead of fetching all tags and filtering in Ruby
      # This is much faster as it avoids fetching every tag from OmniFocus
      matching_tags = tags.filter_map do |tag_name|
        tag_ref = omnifocus_app.flattened_tags[tag_name]
        begin
          tag_ref.get # Verify tag exists
          tag_ref
        rescue
          nil # Tag doesn't exist
        end
      end
      all_tasks_in_container(matching_tags, incomplete_only:)
    end

    private

    def min_sync_interval
      15.minutes.to_i
    end

    # create or update sub_items on a task
    def handle_sub_items(omnifocus_task, external_task)
      debug("omnifocus_task: #{omnifocus_task}, external_task: #{external_task}", options[:debug])
      return unless external_task.respond_to?(:sub_item_count) && external_task.sub_item_count.positive?

      omnifocus_sub_items = omnifocus_task.sub_items
      external_task.sub_items.each do |sub_item|
        if (existing_sub_item = omnifocus_sub_items.find { |omnifocus_sub_item| friendly_titles_match?(omnifocus_sub_item, sub_item) })
          update_item(existing_sub_item, sub_item)
          "Updated sub_item #{sub_item.title} of task #{external_task.title} in Omnifocus"
        else
          add_item(sub_item, omnifocus_task) unless sub_item.completed?
          "Created sub_item #{sub_item.title} of task #{external_task.title} in Omnifocus"
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
        found_task = (inbox_tasks + tagged_tasks(task.tags)).find { |t| t.name.get.strip == task.friendly_title }
        debug("Found task: #{found_task}", options[:debug]) if found_task
        found_task
      else
        debug("called with a native Omnifocus task", options[:debug])
        task
      end
      existing_tag_names = target_task.tags.get.map { |existing_tag| existing_tag.name.get }
      if existing_tag_names.include?(tag.name.get)
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
    rescue
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
        project = if folder
          folder.flattened_projects[project_structure].get
        else
          # If a folder project can't be found, check for any matching project
          omnifocus_app.flattened_projects[project_structure]
        end
      end
      debug("project: #{project.name.get}", options[:debug])
      project.get
      project
    rescue
      puts "The project #{project_structure} does not exist in Omnifocus" if options[:verbose]
      nil
    end

    # Checks that a tag exists in Omnifocus and if it does, returns it
    def tag(name)
      tag = omnifocus_app.flattened_tags[name]
      tag.get
    rescue
      puts "The tag #{name} does not exist in Omnifocus" if options[:verbose]
      nil
    end

    # Maps a list of tag names on an Omnifocus::Task to Omnifocus tags
    def tags(task)
      task.tags.filter_map { |tag| tag(tag) }
    end

    def all_tasks_in_container(container, incomplete_only: false)
      tasks = case container
      when Array
        container.map { |subcontainer| subcontainer.tasks.get.flatten.map { |t| all_omnifocus_sub_items(t) }.flatten.compact.uniq(&:id_) }.flatten
      when Appscript::Reference
        container.tasks.get.flatten.map { |t| all_omnifocus_sub_items(t) }.flatten.compact.uniq(&:id_)
      end
      return tasks unless incomplete_only

      tasks.reject { |task| task.completed.get }
    end

    # adapted from https://github.com/fredoliveira/forecast
    def all_omnifocus_sub_items(task)
      [task] + task.tasks.get.flatten.map { |t| all_omnifocus_sub_items(t) }
    end
  end
end
