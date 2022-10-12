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
    def sync(primary_service)
      tasks = primary_service.tasks_to_sync(tags: ["Omnifocus"])
      existing_tasks = tasks_to_sync(tags: options[:tags], inbox: true)
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length, title: "Omnifocus Tasks") unless options[:quiet]
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| task_title_matches(t, task) })
          update_task(existing_task, task)
        else
          add_task(task) unless task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if options[:debug]
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{tasks.length} #{options[:primary]} items to Omnifocus" unless options[:quiet]
    end

    def tasks_to_sync(tags: nil, inbox: false)
      tasks = tagged_tasks(tags)
      tasks += inbox_tasks if inbox
      tasks.map do |task|
        Task.new(task, @options)
      end
    end
    memo_wise :tasks_to_sync

    def add_task(task, options = {})
      puts "Called #{self.class}##{__method__}" if options[:debug]
      if project(task) && !options[:pretend]
        new_task = project(task).make(new: :task, with_properties: task.properties)
      elsif !options[:pretend]
        new_task = omnifocus.make(new: :inbox_task, with_properties: task.properties)
      elsif options[:pretend] && options[:verbose]
        "Would have added #{task.title} to Omnifocus"
      end
      if new_task && !tags(task).empty?
        tags(task).each do |tag|
          add_tag(tag: tag, task: new_task)
        end
        new_task
      end
    end

    def update_task(existing_task, task, options = {})
      puts "Called #{self.class}##{__method__}" if options[:debug]
      if task.completed? && existing_task.incomplete?
        existing_task.mark_complete unless options[:pretend]
        "Would have marked #{existing_task.title} complete in Omnifocus" if options[:pretend] && options[:verbose]
      elsif !options[:pretend] && !task.completed? # don't add tags to completed tasks
        tags(task).each do |tag|
          add_tag(tag: tag, task: existing_task)
        end
        task
      elsif options[:pretend]
        "Would have updated #{task.title} in Omnifocus"
      end
    end

    private

    def task_title_matches(task, external_task)
      puts "Called #{self.class}##{__method__} with task: #{task}, external_task: #{external_task}" if options[:debug]
      task.title.downcase.strip == external_task.title.downcase.strip
    end

    # Checks if a tag is already on a task, and if not adds it
    def add_tag(task:, tag:)
      puts "Called #{self.class}##{__method__} with task: #{task}, tag: #{tag}" if options[:debug]
      target_task = if task.instance_of?(Omnifocus::Task)
        puts "Finding native Omnifocus task for #{task.title}" if options[:debug]
        found_task = (inbox_tasks + tagged_tasks(task.tags)).find { |t| t.name.get == task.task_title }
        puts "Found task: #{found_task}" if options[:debug]
        found_task
      else
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
    def project(external_task)
      puts "Called #{self.class}##{__method__} looking for project: #{external_task.project}" if options[:debug]
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
    memo_wise :project

    # Checks that a tag exists in Omnifocus and if it does, returns it
    def tag(name)
      tag = omnifocus.flattened_tags[name]
      tag.get
    rescue
      puts "The tag #{name} does not exist in Omnifocus" if options[:verbose]
      nil
    end
    memo_wise :tag

    # Maps a list of tag names on an Omnifocus::Task to Omnifocus tags
    def tags(task)
      task.tags.map { |tag| tag(tag) }.compact
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

    def tagged_tasks(tags = nil)
      target_tags = tags || @options[:tags]
      all_tags = omnifocus.flattened_tags.get
      matching_tags = all_tags.select { |tag| target_tags.include?(tag.name.get) }
      matching_tags.map(&:tasks).map(&:get).flatten.map { |t| all_omnifocus_subtasks(t) }.flatten.compact.uniq(&:id_)
    end
    memo_wise :tagged_tasks

    # adapted from https://github.com/fredoliveira/forecast
    def all_omnifocus_subtasks(task)
      [task] + task.tasks.get.flatten.map { |t| all_omnifocus_subtasks(t) }
    end
  end
end
