# frozen_string_literal: true

require_relative "reminder"
require_relative "../base/service"

module Reminders
  class Service < Base::Service
    attr_reader :reminders

    def initialize(options:)
      # Assumes you already have Reminders installed
      @reminders = Appscript.app.by_name(tag_name)
      super
    end

    def tag_name
      "Reminders"
    end

    # For new tasks on either service, creates new matching ones
    # for existing tasks, first check for an updated_at timestamp
    # and sync from the service with the newer modification
    def sync_with_primary(primary_service)
      tasks = primary_service.tasks_to_sync(tags: [tag_name])
      existing_tasks = tasks_to_sync
    end

    def tasks_to_sync(*)
      sync_maps = options[:reminders_mapping].split(",").map { |mapping| mapping.split("|") }
      reminders_lists = sync_maps.map(&:first)
    end
    memo_wise :tasks_to_sync

    def add_task(external_task, options = {}, parent_object = nil); end

    def update_task(reminder, external_task); end

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      5.minutes.to_i
    end

    def lists
      reminders.lists.get
    end
    memo_wise :lists

    def reminders_in_list(list_name)
      list = lists.find { |list| list.name.get == list_name }
      list.reminders.get
    end
    memo_wise :reminders_in_list

    def friendly_titles_match?(reminder, external_task); end
  end
end
