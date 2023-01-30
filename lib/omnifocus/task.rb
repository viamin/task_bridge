# frozen_string_literal: true

module Omnifocus
  # A representation of an Omnifocus task
  class Task
    prepend MemoWise
    include NoteParser

    WEEKDAY_TAGS = %w[
      Monday
      Tuesday
      Wednesday
      Thursday
      Friday
      Saturday
      Sunday
    ].freeze

    MONTH_TAGS = [
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
    ].freeze

    RELATIVE_TIME_TAGS = [
      "Today",
      "Tomorrow",
      "This Week",
      "Next Week",
      "This Month",
      "Next Month"
    ].freeze

    TIME_TAGS = WEEKDAY_TAGS + MONTH_TAGS + RELATIVE_TIME_TAGS

    attr_reader :options, :id, :title, :due_date, :completed, :completion_date, :start_date, :flagged, :estimated_minutes, :notes, :tags, :project, :updated_at, :subtask_count, :subtasks, :sync_id, :sync_url, :debug_data

    def initialize(task, options)
      @options = options
      @id = read_attribute(task, :id_)
      @title = read_attribute(task, :name)
      containing_project = read_attribute(task, :containing_project)
      @project = if containing_project.respond_to?(:get)
        containing_project.name.get
      else
        ""
      end
      @completed = read_attribute(task, :completed)
      @completion_date = read_attribute(task, :completion_date)
      @start_date = read_attribute(task, :defer_date)
      @estimated_minutes = read_attribute(task, :estimated_minutes)
      @flagged = read_attribute(task, :flagged)

      @sync_id, temp_notes = parsed_notes("sync_id", read_attribute(task, :note))
      @sync_url, @notes = parsed_notes("url", temp_notes)

      @tags = read_attribute(task, :tags)
      @tags = @tags.map { |tag| read_attribute(tag, :name) } unless @tags.nil?
      @due_date = date_from_tags(task, @tags)
      @updated_at = read_attribute(task, :modification_date)
      @subtasks = read_attribute(task, :tasks).map do |subtask|
        Task.new(subtask, @options)
      end
      @subtask_count = @subtasks.count
      @debug_data = task if @options[:debug]
    end

    def provider
      "Omnifocus"
    end

    def completed?
      completed
    end

    def incomplete?
      !completed
    end

    def personal?
      if @options[:uses_personal_tags]
        @tags.intersect?(@options[:personal_tags].split(","))
      elsif @options[:work_tags]&.any?
        !@tags.intersect?(@options[:work_tags].split(","))
      end
    end
    memo_wise :personal?

    def flag!
      original_task.flagged.set(to: true)
    end

    def mark_complete
      debug("Called") if options[:debug]
      original_task.mark_complete
    end

    def original_task
      Service.new(options).omnifocus.flattened_tags[*options[:tags]].tasks[title].get
    end
    memo_wise :original_task

    def containers
      parents = []
      container = original_task.container.get
      container_class = container.class_.get
      # :document is the top level container - anything
      # else is a folder, project, or parent task
      while container_class != :document
        # A quirk of omnifocus seems to be that if a `container` is a project, asking for the `class_` returns `:task` (without a `parent_task`)
        # But if you ask for `containing_project` and ask for its `class_`, it returns `:project`
        # So we need to check for this case
        properties = container.properties_.get
        if properties[:class_] == :task && properties[:parent_class] == :missing_value
          # container is probably actually a :project
          container = container.containing_project.get
          properties = container.properties_.get
        end
        parents << {
          type: properties[:class_],
          name: properties[:name],
          object: container
        }
        container = container.container.get
        container_class = container.class_.get
      end
      parents
    end
    memo_wise :containers

    def friendly_title
      title
    end

    def to_s
      "#{provider}::Task:(#{id})#{title}"
    end

    def sync_notes
      notes_with_values(notes, sync_id:, sync_url:)
    end

    # start_at is a "premium" feature, apparently
    def to_asana
      {
        completed:,
        due_at: due_date&.iso8601,
        liked: flagged,
        name: title,
        notes: sync_notes
        # start_at: start_date&.iso8601
      }.compact
    end

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def to_google(with_due: false, skip_reclaim: false)
      # using to_date since GoogleTasks doesn't seem to care about the time (for due date)
      # and the exact time probably doesn't matter for completed
      google_task = with_due ? { due: due_date&.to_date&.rfc3339 } : {}
      google_task.merge(
        {
          completed: completion_date&.to_date&.rfc3339,
          notes:,
          status: completed ? "completed" : "needsAction",
          title: title + Reclaim::Task.title_addon(self, skip: skip_reclaim)
        }
      ).compact
    end

    def to_reclaim
      time_chunks_required = estimated_minutes.present? ? (estimated_minutes / 15.0).ceil : 1 # defaults to 15 minutes
      {
        alwaysPrivate: true,
        due: due_date&.iso8601,
        eventCategory: personal? ? "PERSONAL" : "WORK",
        eventColor: nil,
        maxChunkSize: 4, # 1 hour
        minChunkSize: 1, # 15 minites
        notes: sync_notes,
        priority: "DEFAULT",
        snoozeUntil: start_date&.iso8601,
        timeChunksRequired: time_chunks_required,
        title:
      }
    end

    private

    # Creates a due date from a tag if there isn't a due date
    def date_from_tags(task, tags)
      task_due_date = read_attribute(task, :due_date)
      return task_due_date unless task_due_date.nil?
      return if tags.empty?

      tag = (tags & TIME_TAGS).first
      date = Chronic.parse(tag)
      return if date.nil?

      if date < Time.now
        date += 1.week if tags & WEEKDAY_TAGS
        date += 1.year if tags & MONTH_TAGS
      end
      date
    end

    def read_attribute(task, attribute, missing_value = nil)
      value = task.send(attribute)
      value = value.get if value.respond_to?(:get)
      value == :missing_value ? missing_value : value
    end
  end
end

# task.properties_.get
# {
#   next_defer_date: :missing_value,
#   flagged: false,
#   should_use_floating_time_zone: true,
#   next_due_date: :missing_value,
#   effectively_dropped: false,
#   modification_date: 2022-09-01 22:44:19 -0700,
#   completion_date: :missing_value,
#   sequential: false,
#   completed: false,
#   repetition_rule: :missing_value,
#   number_of_completed_tasks: 0,
#   containing_document: app("/Applications/OmniFocus.app").default_document,
#   estimated_minutes: :missing_value,
#   number_of_tasks: 0,
#   repetition: :missing_value,
#   container: app("/Applications/OmniFocus.app").default_document.projects.ID("haN858H6IHD").root_task,
#   assigned_container: :missing_value,
#   note: "",
#   creation_date: 2022-09-01 22:44:19 -0700,
#   dropped: false,
#   blocked: false,
#   in_inbox: false,
#   class_: :task,
#   next_: true,
#   number_of_available_tasks: 0,
#   primary_tag: :missing_value,
#   name: "Photocopy of Id for cup",
#   containing_project: app("/Applications/OmniFocus.app").default_document.projects.ID("haN858H6IHD"),
#   effective_due_date: :missing_value,
#   parent_task: app("/Applications/OmniFocus.app").default_document.projects.ID("haN858H6IHD").root_task,
#   completed_by_children: false,
#   effective_defer_date: :missing_value,
#   defer_date: :missing_value,
#   id_: "nXrXR3AGiV2",
#   dropped_date: :missing_value,
#   due_date: :missing_value,
#   effectively_completed: false
# }
