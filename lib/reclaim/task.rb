# frozen_string_literal: true

module Reclaim
  class Task
    attr_reader :options, :id, :title, :notes, :category, :time_required, :time_spent, :time_remaining, :minimum_chunk_size, :maximum_chunk_size, :status, :due_date, :defer_date, :always_private, :debug_data

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
      @tags = default_tags
      @tags = if personal?
        @tags + @options[:personal_tags].split(",")
      else
        @tags + @options[:work_tags].split(",")
      end
      @debug_data = task if @options[:debug]
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

    def task_title
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

    private

    def default_tags
      options[:tags] + ["Reclaim"]
    end

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
