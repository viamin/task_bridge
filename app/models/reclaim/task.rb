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

module Reclaim
  class Task < Base::SyncItem
    PERSONAL = "PERSONAL"
    WORK = "WORK"

    attr_accessor :reclaim_task
    attr_reader :time_required, :time_spent, :time_remaining, :minimum_chunk_size, :maximum_chunk_size, :always_private

    def read_original(only_modified_dates: false)
      super(only_modified_dates:)
      @time_required = read_attribute(reclaim_task, "timeChunksRequired", only_modified_dates:)
      @time_spent = read_attribute(reclaim_task, "timeChunksSpent", only_modified_dates:)
      @time_remaining = read_attribute(reclaim_task, "timeChunksRemaining", only_modified_dates:)
      @minimum_chunk_size = read_attribute(reclaim_task, "minChunkSize", only_modified_dates:)
      @maximum_chunk_size = read_attribute(reclaim_task, "maxChunkSize", only_modified_dates:)
      @always_private = read_attribute(reclaim_task, "alwaysPrivate", only_modified_dates:)
      @tags = default_tags
      @tags = if personal?
        @tags + options[:personal_tags]
      else
        @tags + options[:work_tags]
      end
    end

    def chronic_attributes
      %i[due_date start_date updated_at]
    end

    def external_data
      reclaim_task
    end

    def provider
      "Reclaim"
    end

    def completed?
      time_remaining <= 0
    end

    def incomplete?
      time_remaining.positive?
    end

    def personal?
      item_type == PERSONAL
    end

    def to_h(*_args)
      {
        title:,
        eventColor: nil,
        eventCategory: item_type,
        timeChunksRequired: time_required,
        snoozeUntil: start_date.rfc3339,
        due: due_date.rfc3339, # "2022-10-08T03:00:00.000Z"
        minChunkSize: minimum_chunk_size,
        maxChunkSize: maximum_chunk_size,
        notes:,
        priority: "DEFAULT",
        alwaysPrivate: always_private
      }
    end

    def to_json(*_args)
      to_h.to_json
    end

    class << self
      def from_external(external_task)
        time_chunks_required = external_task.estimated_minutes.present? ? (external_task.estimated_minutes / 15.0).ceil : 1 # defaults to 15 minutes
        {
          alwaysPrivate: true,
          due: external_task.due_date&.iso8601,
          eventCategory: external_task.personal? ? "PERSONAL" : "WORK",
          eventColor: nil,
          maxChunkSize: 4, # 1 hour
          minChunkSize: 1, # 15 minites
          notes: external_task.sync_notes,
          priority: "DEFAULT",
          snoozeUntil: external_task.start_date&.iso8601,
          timeChunksRequired: time_chunks_required,
          title: external_task.title
        }.compact
      end

      # generate a title addition that Reclaim can use to set additional settings
      # Form of TITLE ([DURATION] [DUE_DATE] [NOT_BEFORE] [TYPE])
      # refer to https://help.reclaim.ai/en/articles/4293078-use-natural-language-in-the-google-task-integration
      def title_addon(task, skip: true)
        return if skip

        duration = task.estimated_minutes.nil? ? "" : "for #{task.estimated_minutes} minutes"
        not_before = task.start_date.nil? ? "" : "not before #{task.start_date.to_datetime.strftime("%F")}"
        type = task.personal? ? "type personal" : ""
        due_date = task.due_date.nil? ? "" : "due #{task.due_date.to_datetime.strftime("%F %l %p")}"
        addon_string = "#{type} #{duration} #{not_before} #{due_date}".squeeze(" ").strip
        addon_string.empty? ? "" : " (#{addon_string})"
      end

      def attribute_map
        {
          due_date: "due",
          start_date: "snoozeUntil",
          last_modified: "updated",
          tags: nil,
          item_type: "eventCategory"
        }
      end
    end
  end
end

# {
#   "id" => 2_233_066,
#   "title" => "Test",
#   "notes" => "",
#   "eventCategory" => "WORK", # "PERSONAL"
#   "eventSubType" => "FOCUS", # "OTHER_PERSONAL"
#   "status" => "SCHEDULED",
#   "timeChunksRequired" => 1,
#   "timeChunksSpent" => 0,
#   "timeChunksRemaining" => 1,
#   "minChunkSize" => 1,
#   "maxChunkSize" => 4,
#   "alwaysPrivate" => true,
#   "deleted" => false,
#   "index" => 12_839_000.0,
#   "created" => "2023-01-12T22:53:11.631628-08:00",
#   "updated" => "2023-01-12T22:53:11.638998-08:00",
#   "adjusted" => false,
#   "atRisk" => false,
#   "instances" =>
#  [{ "taskId" => 2_233_066,
#     "eventId" => "e9im6r31d5miqobjedkn6t1dehgn6qpqeoojkchi6cpj0dhm78o0",
#     "eventKey" => "50523/e9im6r31d5miqobjedkn6t1dehgn6qpqeoojkchi6cpj0dhm78o0",
#     "status" => "PENDING",
#     "start" => "2023-01-13T10:45:00-08:00",
#     "end" => "2023-01-13T11:00:00-08:00",
#     "index" => 0,
#     "pinned" => false }],
#   "type" => "TASK",
#   "recurringAssignmentType" => "TASK"
# }
