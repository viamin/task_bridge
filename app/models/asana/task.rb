# frozen_string_literal: true

require_relative "../base/sync_item"

module Asana
  # A representation of an Asana task
  class Task < Base::SyncItem
    include Collectible

    attr_accessor :asana_task
    attr_reader :project, :section, :sub_item_count, :sub_items, :assignee

    after_initialize :read_original

    def read_original
      @project = project_from_memberships(asana_task)
      @sub_item_count = asana_task.fetch("num_subtasks", 0).to_i
      @sub_items = []
      @assignee = asana_task.dig("assignee", "gid")
    end

    def attribute_map
      {
        external_id: "gid",
        title: "name",
        url: "permalink_url",
        due_date: "due_on",
        flagged: "hearted",
        item_type: "resource_type",
        start_date: "start_on",
        last_modified: "modified_at"
      }
    end

    def chronic_attributes
      %i[completed_at due_date due_at updated_at start_date start_at]
    end

    def external_data
      asana_task
    end

    def provider
      "Asana"
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

    class << self
      def from_external(external_item)
        {
          completed: external_item.completed?,
          due_at: external_item.due_date&.iso8601,
          liked: external_item.flagged,
          name: external_item.title,
          notes: external_item.sync_notes
          # start_at is a "premium" feature, apparently
          # start_at: external_item.start_date&.iso8601
        }.compact
      end

      def requested_fields
        %w[name permalink_url completed completed_at projects due_on due_at modified_at hearted notes start_on start_at num_subtasks memberships.section.name memberships.project.name subtasks_name assignee]
      end
    end

    private

    # try to read the project and sections from the memberships array
    # If there isn't anything there, use the projects array
    def project_from_memberships(asana_task)
      if asana_task["memberships"].any?
        # Asana supports multiple sections, but TaskBridge currently supports only one per task
        project = asana_task["memberships"].first.dig("project", "name")
        section = asana_task["memberships"].first.dig("section", "name")
        (section == "Untitled section") ? project : "#{project}:#{section}"
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
