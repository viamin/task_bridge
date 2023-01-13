# frozen_string_literal: true

module Reclaim
  class Task
    prepend MemoWise
    include NoteParser

    attr_reader :options, :id, :title, :notes, :category, :time_required, :time_spent, :time_remaining, :minimum_chunk_size, :maximum_chunk_size, :status, :due_date, :defer_date, :always_private, :updated_at, :sync_id, :debug_data

    def initialize(reclaim_task, options)
      @options = options
      @id = reclaim_task["id"]
      @title = reclaim_task["title"]
      @category = reclaim_task["eventCategory"]
      @time_required = reclaim_task["timeChunksRequired"]
      @time_spent = reclaim_task["timeChunksSpent"]
      @time_remaining = reclaim_task["timeChunksRemaining"]
      @minimum_chunk_size = reclaim_task["minChunkSize"]
      @maximum_chunk_size = reclaim_task["maxChunkSize"]
      @status = reclaim_task["status"]
      @due_date = Chronic.parse(reclaim_task["due"])
      @defer_date = Chronic.parse(reclaim_task["snoozeUntil"])
      @updated_at = Chronic.parse(reclaim_task["updated"])
      @always_private = reclaim_task["alwaysPrivate"]
      @tags = default_tags
      @tags = if personal?
        @tags + @options[:personal_tags].split(",")
      else
        @tags + @options[:work_tags].split(",")
      end

      @sync_id, @notes = parsed_notes("sync_id", reclaim_task["notes"])

      @debug_data = reclaim_task if @options[:debug]
    end

    def provider
      "Reclaim"
    end

    def complete?
      time_remaining <= 0
    end

    def incomplete?
      time_remaining.positive?
    end

    def personal?
      category == "PERSONAL"
    end

    def friendly_title
      title
    end

    def to_json(*_args)
      {
        title:,
        eventColor: nil,
        eventCategory: category,
        timeChunksRequired: time_required,
        snoozeUntil: defer_date.rfc3339,
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

    private

    def default_tags
      options[:tags] + ["Reclaim"]
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
