# frozen_string_literal: true

require_relative "../base/sync_item"

module GoogleTasks
  # A representation of an Google task
  class Task < Base::SyncItem
    def initialize(google_task:, options:)
      super(sync_item: google_task, options:)
    end

    def attribute_map
      {
        url: "self_link",
        due_date: "due",
        type: "kind",
        updated_at: "updated"
      }
    end

    def provider
      "GoogleTasks"
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
