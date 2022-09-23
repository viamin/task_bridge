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
    attr_reader :title, :due_date

    def initialize(task, due_date)
      @due_date = due_date
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
      @tag = read_attribute(task, :primary_tag)
    end

    def render
      title_length = @title.length
      puts "=" * title_length
      puts @title
      puts "=" * title_length
      puts "Due: #{@due_date.strftime("%d %B %Y")}"
      puts "Project: #{@project}" unless @project.empty?
      puts "Notes: #{@note}\n" unless @note.empty?
      puts "\n"
    end

    private

    def read_attribute(task, attribute)
      attribute = task.send(attribute).get
      attribute == :missing_value ? "" : attribute
    end
  end
end
