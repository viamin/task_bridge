module Omnifocus
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
  class Task
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

    attr_reader :title, :due_date, :completed, :defer_date, :estimated_minutes, :flagged, :note, :tags, :project

    def initialize(task, options)
      @options = options
      @title = read_attribute(task, :name)
      containing_project = task.containing_project.get
      @project = if containing_project == :missing_value
        ""
      else
        containing_project.name.get
      end
      @completed = read_attribute(task, :completed)
      @defer_date = read_attribute(task, :defer_date)
      @estimated_minutes = read_attribute(task, :estimated_minutes)
      @flagged = read_attribute(task, :flagged)
      @note = read_attribute(task, :note)
      @tags = read_attribute(task, :tags)
      @tags = @tags.map(&:name).map(&:get) unless @tags.nil? || @tags.empty?
      @due_date = date_from_tags(task, @tags)
    end

    def render
      title_length = @title.length
      puts "=" * title_length
      puts @title
      puts "=" * title_length
      puts "Due: #{@due_date.strftime("%d %B %Y")}" unless @due_date.nil?
      puts "Defer: #{@defer_date.strftime("%d %B %Y")}" unless @defer_date.nil?
      puts "Project: #{@project}" unless @project.empty?
      puts "Notes: #{@note}\n" unless @note.empty?
      puts "Tags: #{@tags.join(", ")}\n" unless @tags.empty?
      puts "Estimate: #{@estimated_minutes} minutes\n" unless @estimated_minutes.nil?
      puts "\n"
    end

    def is_personal?
      if @options[:personal_tags].any?
        (@tags & @options[:personal_tags]).any?
      elsif @options[:work_tags].any?
        (@tags & @options[:work_tags]).empty?
      end
    end

    private

    # Creates a due date from a tag if there isn't a due date
    def date_from_tags(task, tags)
      task_due_date = read_attribute(task, :due_date)
      return task_due_date unless task_due_date.nil?
      return if tags.empty?

      tag = (tags & TIME_TAGS).first
      Chronic.parse(tag)
    end

    def read_attribute(task, attribute)
      attribute = task.send(attribute).get
      attribute == :missing_value ? nil : attribute
    end
  end
end
