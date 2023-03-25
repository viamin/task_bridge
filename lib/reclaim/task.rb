# frozen_string_literal: true

require_relative "../base/sync_item"

module Reclaim
  class Task < Base::SyncItem
    PERSONAL = "PERSONAL"
    WORK = "WORK"

    attr_reader :time_required, :time_spent, :time_remaining, :minimum_chunk_size, :maximum_chunk_size, :always_private

    def initialize(reclaim_task:, options:)
      super(sync_item: reclaim_task, options:)

      @time_required = read_attribute(reclaim_task, "timeChunksRequired")
      @time_spent = read_attribute(reclaim_task, "timeChunksSpent")
      @time_remaining = read_attribute(reclaim_task, "timeChunksRemaining")
      @minimum_chunk_size = read_attribute(reclaim_task, "minChunkSize")
      @maximum_chunk_size = read_attribute(reclaim_task, "maxChunkSize")
      @always_private = read_attribute(reclaim_task, "alwaysPrivate")
      @tags = default_tags
      @tags = if personal?
        @tags + @options[:personal_tags].split(",")
      else
        @tags + @options[:work_tags].split(",")
      end
    end

    def attribute_map
      {
        due_date: "due",
        start_date: "snoozeUntil",
        updated_at: "updated",
        tags: nil,
        type: "eventCategory"
      }
    end

    def chronic_attributes
      %i[due_date start_date updated_at]
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
      type == "PERSONAL"
    end

    def to_json(*_args)
      {
        title:,
        eventColor: nil,
        eventCategory: type,
        timeChunksRequired: time_required,
        snoozeUntil: start_date.rfc3339,
        due: due_date.rfc3339, # "2022-10-08T03:00:00.000Z"
        minChunkSize: minimum_chunk_size,
        maxChunkSize: maximum_chunk_size,
        notes:,
        priority: "DEFAULT",
        alwaysPrivate: always_private
      }.to_json
    end

    class << self
      # generate a title addition that Reclaim can use to set additional settings
      # Form of TITLE ([DURATION] [DUE_DATE] [NOT_BEFORE] [TYPE])
      # refer to https://help.reclaim.ai/en/articles/4293078-use-natural-language-in-the-google-task-integration
      def title_addon(task, skip: true)
        return if skip

        duration = task.estimated_minutes.nil? ? "" : "for #{task.estimated_minutes} minutes"
        not_before = task.start_date.nil? ? "" : "not before #{task.start_date.to_datetime.strftime('%F')}"
        type = task.personal? ? "type personal" : ""
        due_date = task.due_date.nil? ? "" : "due #{task.due_date.to_datetime.strftime('%F %l %p')}"
        addon_string = "#{type} #{duration} #{not_before} #{due_date}".squeeze(" ").strip
        addon_string.empty? ? "" : " (#{addon_string})"
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
