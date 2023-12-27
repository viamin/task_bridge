# frozen_string_literal: true

require_relative "../base/sync_item"

module GoogleTasks
  # A representation of an Google task
  class Task < Base::SyncItem
    attr_accessor :google_task

    def attribute_map
      {
        url: "self_link",
        due_date: "due",
        item_type: "kind",
        last_modified: "updated"
      }
    end

    def external_data
      google_task
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
