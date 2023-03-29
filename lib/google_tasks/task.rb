# frozen_string_literal: true

require_relative "../base/sync_item"

module GoogleTasks
  # A representation of an Google task
  class Task < Base::SyncItem
    def initialize(google_task:, options:)
      super(sync_item: google_task, options:)

      @project = project_from_memberships(google_task)
      @sub_item_count = google_task.fetch("num_subtasks", 0).to_i
      @sub_items = []
      @assignee = google_task.dig("assignee", "gid")
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

    class << self
      # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
      def from_external(external_task, skip_reclaim: false)
        {
          completed: external_task.completed_at&.to_date&.rfc3339,
          due: external_task.due_date&.to_date&.rfc3339,
          notes: external_task.sync_notes,
          status: external_task.completed ? "completed" : "needsAction",
          title: external_task.title + Reclaim::Task.title_addon(self, skip: skip_reclaim)
        }.compact
      end
    end
  end
end
