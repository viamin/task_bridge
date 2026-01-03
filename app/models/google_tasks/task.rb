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

module GoogleTasks
  # A representation of an Google task
  class Task < Base::SyncItem
    attr_accessor :google_task

    def external_data
      google_task
    end

    def provider
      "GoogleTasks"
    end

    class << self
      def attribute_map
        {
          url: "self_link",
          due_date: "due",
          item_type: "kind",
          last_modified: "updated"
        }
      end

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
