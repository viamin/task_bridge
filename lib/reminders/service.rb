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

    def sync_strategies
      [:to_primary]
    end

    # Since Reminders via Applescript doesn't currently support tags, we use the mapping
    # REMINDERS_LIST_MAPPING=Reminder list 1~Primary list,Reminder list 2~Primary list 2
    def items_to_sync(*)
      sync_maps = options[:reminders_mapping].split(",").to_h { |mapping| mapping.split("~") }
      reminders_lists = sync_maps.keys
      debug("reminders_lists: #{reminders_lists}", options[:debug])
      merged_reminders = reminders_lists.map { |reminders_list| reminders_in_list(reminders_list) }.flatten
      merged_reminders.map { |reminder| Reminder.new(reminder:, options:) }
    end
    memo_wise :items_to_sync

    def add_item(external_task, parent_object = nil)
      debug("external_task: #{external_task}, parent_object: #{parent_object}", options[:debug])
      if !options[:pretend]
        new_reminder = list(external_task).make(new: :reminder, with_properties: Reminder.from_external(external_task))
        new_reminder_id = new_reminder.id_.get
        update_sync_data(external_task, new_reminder_id) if options[:update_ids_for_existing]
        new_reminder
      elsif options[:pretend] && options[:verbose]
        "Would have added #{external_task.title} to Reminders"
      end
    end

    # def patch_item(reminder, attributes_hash); end

    def update_item(reminder, external_task)
      debug("reminder: #{reminder}, external_task: #{external_task}", options[:debug])
      if options[:max_age_timestamp] && external_task.updated_at && (external_task.updated_at < options[:max_age_timestamp])
        "Last modified more than #{options[:max_age]} ago - skipping #{external_task.title}"
      elsif external_task.completed? && reminder.incomplete?
        debug("Complete state doesn't match", options[:debug])
        if options[:pretend]
          "Would have marked #{reminder.title} complete in Reminders"
        else
          reminder.mark_complete unless options[:pretend]
        end
        reminder_id = reminder.id_.get
        update_sync_data(external_task, reminder_id) if options[:update_ids_for_existing]
        external_task
      elsif options[:pretend]
        "Would have updated #{external_task.title} in Reminders"
      end
    end

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
      reminder_list.reminders.get
    end
    memo_wise :reminders_in_list
  end
end
