# frozen_string_literal: true

require_relative "../base/sync_item"

module Omnifocus
  # A representation of an Omnifocus task
  class Task < Base::SyncItem
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

    attr_reader :estimated_minutes, :tags, :project, :subtask_count, :subtasks, :due_date # :completion_date

    def initialize(omnifocus_task:, options:)
      super(sync_item: omnifocus_task, options:)

      containing_project = read_attribute(omnifocus_task, :containing_project)
      @project = if containing_project.respond_to?(:get)
        containing_project.name.get
      else
        ""
      end
      @estimated_minutes = read_attribute(omnifocus_task, :estimated_minutes)

      @tags = read_attribute(omnifocus_task, :tags)
      @tags = @tags.map { |tag| read_attribute(tag, :name) } unless @tags.nil?
      @due_date = date_from_tags(omnifocus_task, @tags)
      @subtasks = read_attribute(omnifocus_task, :tasks).map do |subtask|
        Task.new(omnifocus_task: subtask, options: @options)
      end
      @subtask_count = @subtasks.count
    end

    def attribute_map
      {
        id: "id_",
        completed_at: "completion_date",
        due_date: nil,
        notes: "note",
        start_date: "defer_date",
        status: nil,
        tags: nil,
        title: "name",
        updated_at: "modification_date"
      }
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
      Service.new(options:).omnifocus_app.flattened_tags[*options[:tags]].tasks[title].get
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
