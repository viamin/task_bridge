# frozen_string_literal: true

require_relative "../base/sync_item"

module Asana
  # A representation of an Asana task
  class Task < Base::SyncItem
    attr_reader :project, :section, :subtask_count, :subtasks, :assignee

    def initialize(asana_task:, options:)
      super(sync_item: asana_task, options:)

      @project = project_from_memberships(asana_task)
      @subtask_count = asana_task.fetch("num_subtasks", 0).to_i
      @subtasks = []
      @assignee = asana_task.dig("assignee", "gid")
    end

    def attribute_map
      {
        id: "gid",
        title: "name",
        url: "permalink_url",
        due_date: "due_on",
        flagged: "hearted",
        type: "resource_type",
        start_date: "start_on",
        updated_at: "modified_at"
      }
    end

    def chronic_attributes
      %i[completed_at due_date due_at updated_at start_date start_at]
    end

    def provider
      "Asana"
    end

    def self.requested_fields
      %w[name permalink_url completed completed_at projects due_on due_at modified_at hearted notes start_on start_at num_subtasks memberships.section.name memberships.project.name subtasks_name assignee]
    end

    def completed?
      completed
    end

    def open?
      !completed?
    end

    # For now, default to true
    def personal?
      true
    end

    # fields required for Asana
    def to_json(*)
      {
        data: {
          completed: completed?,
          due_at: due_at&.iso8601,
          due_on: due_date&.to_date&.iso8601,
          liked: flagged,
          notes: sync_notes,
          name: title,
          start_at: start_at&.iso8601,
          start_on: start_date&.to_date&.iso8601,
          projects: [project["gid"]]
        }.compact
      }.to_json
    end

    def sync_url
      url
    end

    #       #####
    #      #     # ###### #####  #    # #  ####  ######  ####
    #      #       #      #    # #    # # #    # #      #
    #       #####  #####  #    # #    # # #      #####   ####
    #            # #      #####  #    # # #      #           #
    #      #     # #      #   #   #  #  # #    # #      #    #
    #       #####  ###### #    #   ##   #  ####  ######  ####

    # Fields required for omnifocus service
    def to_omnifocus(with_subtasks: false)
      omnifocus_properties = {
        name: friendly_title,
        note: sync_notes,
        flagged:,
        completion_date: completed_at,
        defer_date: start_at || start_date,
        due_date: due_at || due_date
      }.compact
      omnifocus_properties[:subtasks] = subtasks.map(&:to_omnifocus) if with_subtasks
      omnifocus_properties
    end
    memo_wise :to_omnifocus

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def to_google(with_due: false, skip_reclaim: false)
      # using to_date since GoogleTasks doesn't seem to care about the time (for due date)
      # and the exact time probably doesn't matter for completed
      google_task = with_due ? { due: due_date&.to_date&.rfc3339 } : {}
      google_task.merge(
        {
          completed: completed_at&.to_date&.rfc3339,
          notes: sync_notes,
          status: completed ? "completed" : "needsAction",
          title: title + Reclaim::Task.title_addon(self, skip: skip_reclaim)
        }
      ).compact
    end

    private

    # try to read the project and sections from the memberships array
    # If there isn't anything there, use the projects array
    def project_from_memberships(asana_task)
      if asana_task["memberships"].any?
        # Asana supports multiple sections, but TaskBridge currently supports only one per task
        project = asana_task["memberships"].first.dig("project", "name")
        section = asana_task["memberships"].first.dig("section", "name")
        section == "Untitled section" ? project : "#{project}:#{section}"
      else
        # we'll only sync a task with one project at a time
        asana_task["projects"].first
      end
    end

    # {
    #   data: {
    #     gid: "1203188830269587",
    #     assignee: {
    #       "gid": "1172102786176655",
    #       "name": "Bart Agapinan",
    #       "resource_type": "user"
    #     },
    #     assignee_status: "upcoming",
    #     completed: false,
    #     completed_at: null,
    #     created_at: "2022-10-18T05:45:35.090Z",
    #     due_at: "2022-10-19T05:30:00.000Z",
    #     due_on: "2022-10-18",
    #     followers: [
    #       {
    #         gid: "1172102786176655",
    #         name: "Bart Agapinan",
    #         resource_type: "user"
    #       }
    #     ],
    #     hearted: false,
    #     hearts: [],
    #     liked: false,
    #     likes: [],
    #     memberships: [
    #       {
    #         project: {
    #           gid: "1203188830269576",
    #           name: "TaskBridge",
    #           resource_type: "project"
    #         },
    #         section: {
    #           gid: "1203188830269577",
    #           name: "Untitled section",
    #           resource_type: "section"
    #         }
    #       }
    #     ],
    #     modified_at: "2022-10-18T05:45:44.967Z",
    #     name: "Due Time Task",
    #     notes: "",
    #     num_hearts: 0,
    #     num_likes: 0,
    #     parent: {
    #       "gid": "1203416874549042",
    #       "name": "Test task with subtasks",
    #       "resource_type": "task",
    #       "resource_subtype": "default_task"
    #     },
    #     num_subtasks: 0,
    #     permalink_url: "https://app.asana.com/0/1203188830269576/1203188830269587",
    #     projects: [
    #       {
    #         gid: "1203188830269576",
    #         name: "TaskBridge",
    #         resource_type: "project"
    #       }
    #     ],
    #     resource_type: "task",
    #     start_at: null,
    #     start_on: null,
    #     tags: [],
    #     resource_subtype: "default_task",
    #     workspace: {
    #       gid: "498346170860",
    #       name: "Personal Projects",
    #       resource_type: "workspace"
    #     }
    #   }
    # }
  end
end
