module Reclaim
  class Task
    attr_reader :options, :id, :title, :notes, :category, :time_required, :time_spent, :time_remaining, :minimum_chunk_size, :maximum_chunk_size, :status, :due_date, :defer_date, :always_private
    def initialize(task, options)
      @options = options
      @id = task["id"]
      @title = task["title"]
      @notes = task["notes"]
      @category = task["eventCategory"]
      @time_required = task["timeChunksRequired"]
      @time_spent = task["timeChunksSpent"]
      @time_remaining = task["timeChunksRemaining"]
      @minimum_chunk_size = task["minChunkSize"]
      @maximum_chunk_size = task["maxChunkSize"]
      @status = task["status"]
      @due_date = Chronic.parse(task["due"])
      @defer_date = Chronic.parse(task["snoozeUntil"])
      @private = task["alwaysPrivate"]
    end

    def render
      # TODO
    end

    def complete?
      time_remaining <= 0
    end

    def incomplete?
      time_remaining > 0
    end

    def is_personal?
      category == "PERSONAL"
    end

    def to_json
      {
        title: title,
        eventColor: nil,
        eventCategory: category,
        timeChunksRequired: time_required,
        snoozeUntil: defer_date.rfc3339,
        due: due_date.rfc3339, # "2022-10-08T03:00:00.000Z"
        minChunkSize: minimum_chunk_size,
        maxChunkSize: maximum_chunk_size,
        notes: notes,
        priority: "DEFAULT",
        alwaysPrivate: always_private
      }.to_json
    end

    private

    def visible_attributes
      {
        completed: @completed,
        completion_date: @completion_date&.strftime("%l %p - %b %d"),
        due: @due_date&.strftime("%l %p - %b %d"),
        defer: @defer_date&.strftime("%b %d"),
        project: @project,
        notes: @note,
        tags: @tags&.join(", "),
        estimated_minutes: @estimated_minutes
      }
    end
  end
end
