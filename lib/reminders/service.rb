# frozen_string_literal: true

require_relative "reminder"
require_relative "../base/service"

module Reminders
  class Service < Base::Service
    attr_reader :reminders_app

    def initialize(options:)
      super
      # Assumes you already have Reminders installed
      @reminders_app = Appscript.app.by_name(friendly_name)
    end

    def item_class
      Reminder
    end

    def friendly_name
      "Reminders"
    end

    # For new tasks on either service, creates new matching ones
    # for existing tasks, first check for an updated_at timestamp
    # and sync from the service with the newer modification
    def sync_with_primary(primary_service)
      tasks = primary_service.tasks_to_sync(tags: [friendly_name])
      existing_tasks = items_to_sync
    end

    def items_to_sync(*)
      sync_maps = options[:reminders_mapping].split(",").map { |mapping| mapping.split("~") }
      reminders_lists = sync_maps.map(&:first)
    end
    memo_wise :items_to_sync

    def add_item(external_task, parent_object = nil); end

    def update_item(reminder, external_task); end

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      5.minutes.to_i
    end

    def lists
      reminders_app.lists.get
    end
    memo_wise :lists

    def reminders_in_list(list_name)
      reminder_list = lists.find { |list| list.name.get == list_name }
      reminder_list.reminders_app.get
    end
    memo_wise :reminders_in_list
  end
end
