# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_items
#
#  id                 :integer          not null, primary key
#  completed          :boolean
#  completed_at       :datetime
#  completed_on       :datetime
#  due_at             :datetime
#  due_date           :datetime
#  flagged            :boolean
#  item_type          :string
#  last_modified      :datetime
#  notes              :string
#  start_at           :datetime
#  start_date         :datetime
#  status             :string
#  title              :string
#  type               :string
#  url                :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  external_id        :string
#  parent_item_id     :integer
#  sync_collection_id :integer
#
# Indexes
#
#  index_sync_items_on_parent_item_id      (parent_item_id)
#  index_sync_items_on_sync_collection_id  (sync_collection_id)
#
# Foreign Keys
#
#  parent_item_id      (parent_item_id => sync_items.id)
#  sync_collection_id  (sync_collection_id => sync_collections.id)
#

module Asana
  # A representation of an Asana task
  class Task < Base::SyncItem
    include Collectible

    attr_accessor :asana_task
    attr_reader :project, :section, :sub_item_count, :sub_items, :assignee

    def read_original(only_modified_dates: false)
      super(only_modified_dates:)
      unless only_modified_dates
        @project = project_from_memberships(asana_task)
        @sub_item_count = asana_task.fetch("num_subtasks", 0).to_i
        @sub_items = []
        @assignee = asana_task.dig("assignee", "gid")
      end
      self
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
      completed_at.present?
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

      def requested_fields(only_modified_dates: false)
        # the following hash contains keys that are task attributes
        # the value is whether it is needed when only_modified_dates is true
        fields = {
          name: false,
          permalink_url: false,
          completed: false,
          completed_at: true,
          projects: true,
          due_on: false,
          due_at: false,
          modified_at: true,
          hearted: false,
          notes: false,
          start_on: false,
          start_at: false,
          num_subtasks: false,
          "memberships.section.name": true,
          "memberships.project.name": true,
          subtasks_name: false,
          assignee: false
        }.stringify_keys
        request_fields = only_modified_dates ? fields.select { |_key, value| value } : fields
        request_fields.keys
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
    end

    private

    # try to read the project and sections from the memberships array
    # If there isn't anything there, use the projects array
    def project_from_memberships(asana_task)
      if asana_task["memberships"]&.any?
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
