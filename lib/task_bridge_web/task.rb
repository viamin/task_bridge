# frozen_string_literal: true

require_relative "../base/sync_item"

module TaskBridgeWeb
  class Task < Base::SyncItem
    attr_reader :project_id, :status

    def initialize(task_bridge_web_task:, options:)
      super(sync_item: task_bridge_web_task, options:)
      @project_id = task_bridge_web_task["project_id"]
      @status = task_bridge_web_task["status"]
    end

    def attribute_map
      {
        id: "id",
        title: "title",
        notes: "description",
        completed: "completed",
        due_date: "due_date",
        created_at: "created_at",
        updated_at: "updated_at",
        url: "url"
      }
    end

    def chronic_attributes
      %i[due_date created_at updated_at]
    end

    def provider
      "TaskBridgeWeb"
    end

    def completed?
      completed || status == "completed"
    end

    def open?
      !completed?
    end

    class << self
      def from_external(external_task)
        {
          title: external_task.title,
          description: external_task.sync_notes,
          completed: external_task.completed?,
          due_date: external_task.due_date&.iso8601,
          status: external_task.completed? ? "completed" : "active"
        }.compact
      end
    end
  end
end
