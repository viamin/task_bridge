require_relative "../task_bridge/sync_item"

module Omnifocus
  class Task < TaskBridge::SyncItem
    TIME_TAGS = [
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
    ].freeze

    attr_reader :options, :id, :title, :due_date, :completed, :completion_date, :defer_date, :estimated_minutes, :flagged, :note, :tags, :project

    def initialize(task, options)
      @options = options
      @id = read_attribute(task, :id_)
      @title = read_attribute(task, :name)
      containing_project = read_attribute(task, :containing_project)
      # containing_project = task.containing_project.get
      @project = if containing_project.respond_to?(:get)
        containing_project.name.get
      else
        ""
      end
      # @project = if containing_project == :missing_value
      #   ""
      # else
      #   containing_project.name.get
      # end
      @completed = read_attribute(task, :completed)
      @completion_date = read_attribute(task, :completion_date)
      @defer_date = read_attribute(task, :defer_date)
      @estimated_minutes = read_attribute(task, :estimated_minutes)
      @flagged = read_attribute(task, :flagged)
      @note = read_attribute(task, :note)
      @tags = read_attribute(task, :tags)
      @tags = @tags.map { |tag| read_attribute(tag, :name) } unless @tags.nil?
      # @tags = @tags.map(&:name).map(&:get) unless @tags.nil? || @tags.empty?
      @due_date = date_from_tags(task, @tags)
      super
    end

    def render
      title_length = @title.length
      puts "=" * title_length
      puts @title
      puts "=" * title_length
      visible_attributes.each do |name, attribute|
        puts "#{name.to_s.humanize}: #{attribute}" unless attribute.nil?
      end
      puts "\n"
    end

    def incomplete?
      !completed
    end

    def is_personal?
      if @options[:uses_personal_tags]
        (@tags & @options[:personal_tags].split(",")).any?
      elsif @options[:work_tags]&.any?
        (@tags & @options[:work_tags].split(",")).empty?
      end
    end

    def mark_complete
      original_task.mark_complete
    end

    def self.convert_task(external_task)
      return self if external_task.source == "Omnifocus"

      Task.new(external_task.omnifocus_hash)
    end

    #   #####
    #  #     #  ####  #    # #    # ###### #####  ##### ###### #####   ####
    #  #       #    # ##   # #    # #      #    #   #   #      #    # #
    #  #       #    # # #  # #    # #####  #    #   #   #####  #    #  ####
    #  #       #    # #  # # #    # #      #####    #   #      #####       #
    #  #     # #    # #   ##  #  #  #      #   #    #   #      #   #  #    #
    #   #####   ####  #    #   ##   ###### #    #   #   ###### #    #  ####

    def reclaim_hash
      category = is_personal? ? "PERSONAL" : "WORK"
      time_required = (estimated_minutes / 15.0).ceil
      time_spent = completed ? time_required : 0
      {
        title: title,
        eventCategory: category,
        timeChunksRequired: time_required,
        timeChunksSpent: time_spent,
        timeChunksRemaining: time_required - time_spent,
        snoozeUntil: defer_date.rfc3339,
        due: due_date.rfc3339,
        notes: note,
        alwaysPrivate: true
      }.as_json
    end

    def google_tasks_hash
      {
        completed: completion_date.rfc3339,
        due: due_date.rfc3339,
        notes: note,
        status: completed ? "completed" : "needsAction",
        title: title
      }.as_json
    end

    private

    def visible_attributes
      {
        completed: @completed,
        completion_date: @completion_date&.strftime("%l %p - %b %d"),
        due: @due_date&.strftime("%l %p - %b %d"),
        defer: @defer_date&.strftime("%b %d"),
        project: @project,
        notes: @note,
        tags: @tags&.join(", "),
        estimated_minutes: @estimated_minutes
      }
    end

    # Creates a due date from a tag if there isn't a due date
    def date_from_tags(task, tags)
      task_due_date = read_attribute(task, :due_date)
      return task_due_date unless task_due_date.nil?
      return if tags.empty?

      tag = (tags & TIME_TAGS).first
      Chronic.parse(tag)
    end

    def original_task
      Service.new(options).omnifocus.flattened_tags["Github"].tasks[title].get
    end

    def read_attribute(task, attribute)
      value = task.send(attribute)
      if value.respond_to?(:get)
        value = value.get
      end
      value == :missing_value ? nil : value
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
