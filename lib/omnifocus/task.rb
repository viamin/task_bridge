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

    attr_reader :estimated_minutes, :tags, :project, :sub_item_count, :sub_items, :due_date # :completion_date

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
      @sub_items = read_attribute(omnifocus_task, :tasks).map do |sub_item|
        Task.new(omnifocus_task: sub_item, options: @options)
      end
      @sub_item_count = @sub_items.count
    end

    def id_
      OpenStruct.new(get: id)
    end

    # setting some of these as nil so they will be skipped in the superclass initialization
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
      debug("Called", options[:debug])
      original_task.mark_complete
    end

    def original_task(include_inbox: false)
      search_tasks = if include_inbox
        (service.inbox_tasks + service.tagged_tasks(tags))
      else
        service.omnifocus_app.flattened_tags[*options[:tags]].tasks.get
      end
      search_tasks.find { |task| task.id_.get == id }
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

    def url
      Task.url(id)
    end

    def update_attributes(attributes)
      attributes.each do |key, value|
        original_attribute_key = attribute_map[key].to_sym
        original_task.send(original_attribute_key).set(value)
      end
    end

    class << self
      def url(id)
        "omnifocus:///task/#{id}"
      end

      def from_external(external_item, with_sub_items: false)
        omnifocus_properties = {
          name: external_item.try(:friendly_title) || external_item.try(:title),
          note: external_item.try(:external_sync_notes) || external_item.try(:notes),
          flagged: external_item.try(:flagged),
          completion_date: external_item.try(:completed_at) || external_item.try(:completed_on),
          defer_date: external_item.try(:start_at) || external_item.try(:start_date),
          due_date: external_item.try(:due_at) || external_item.try(:due_date),
          estimated_minutes: external_item.try(:estimated_minutes)
        }.compact
        return omnifocus_properties unless with_sub_items

        omnifocus_properties[:sub_items] = external_item.sub_items.map do |sub_item|
          Task.from_external(sub_item, with_sub_items:)
        end
        omnifocus_properties
      end
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
