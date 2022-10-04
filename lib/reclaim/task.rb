require_relative "../task_bridge/sync_item"

module Reclaim
  class Task < TaskBridge::SyncItem
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
      @tags = ["Reclaim"]
      @tags = if is_personal?
        @tags + @options[:personal_tags].split(",")
      else
        @tags + @options[:work_tags].split(",")
      end
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

    def self.convert_task(external_task)
      return self if external_task.source == "Reclaim"

      Task.new(external_task.reclaim_hash)
    end

    #   #####
    #  #     #  ####  #    # #    # ###### #####  ##### ###### #####   ####
    #  #       #    # ##   # #    # #      #    #   #   #      #    # #
    #  #       #    # # #  # #    # #####  #    #   #   #####  #    #  ####
    #  #       #    # #  # # #    # #      #####    #   #      #####       #
    #  #     # #    # #   ##  #  #  #      #   #    #   #      #   #  #    #
    #   #####   ####  #    #   ##   ###### #    #   #   ###### #    #  ####

    def google_tasks_hash
      {
        completed: complete? ? Time.now.rcf3339 : nil,
        due: due_date.rfc3339,
        notes: notes,
        status: complete ? "completed" : "needsAction",
        title: title
      }.as_json
    end

    def omnifocus_hash
      tags = if is_personal?
        if options[:uses_personal_tags]
          options[:personal_tags].split(",")
        else
          options[:work_tags].split(",")
        end
      end
      tags = tags << "Reclaim"
      {
        title: title,
        completed: complete,
        defer_date: defer_date,
        estimated_minutes: time_remaining * 15,
        note: notes,
        tags: tags,
        due_date: due_date
      }
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
