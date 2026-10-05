# frozen_string_literal: true

module Reminders
  class Service < Base::Service
    include Base::AppleScriptLoader
    include GlobalOptions

    attr_reader :reminders_app, :authorized

    def initialize(options: nil)
      super
      ensure_appscript_loaded!
      # Assumes you already have Reminders installed
      @reminders_app = Appscript.app.by_name(friendly_name)
      @authorized = true
    rescue LoadError, StandardError => e
      # If Reminders app is not available, skip the service
      puts "Reminders initialization failed: #{e.message}" unless self.options[:quiet]
      @reminders_app = nil
      @authorized = false
    end

    def item_class
      Reminder
    end

    def friendly_name
      "Reminders"
    end

    def sync_strategies
      %i[from_primary to_primary]
    end

    def deletion_detection_strategy
      # items_to_sync enumerates the complete configured lists, so a
      # previously observed reminder absent from all of them left
      # TaskBridge's view — but deleted, cleared, and moved-to-another-list
      # are indistinguishable, hence the weaker no_longer_visible state
      # (#220).
      Disappearance::Strategy.full_list_absence(
        state: Disappearance::States::NO_LONGER_VISIBLE,
        confidence: "medium"
      )
    end

    def deletion_detection_scope_available?
      # A renamed or deleted Reminders list makes every reminder in it look
      # absent; tombstones are suppressed unless every mapped list was found.
      # An unreadable enumeration (AppleScript failure) also counts as an
      # unavailable scope rather than evidence of deletion (#220).
      return false unless authorized

      names = readable_list_names
      mapped_list_names.all? { |name| names.include?(name) }
    end

    # Since Reminders via Applescript doesn't currently support tags, we use the mapping
    # REMINDERS_LIST_MAPPING=Reminder list 1~Primary list,Reminder list 2~Primary list 2
    def items_to_sync(*, **)
      return [] unless authorized
      return [] if options[:reminders_mapping].nil?

      sync_maps = options[:reminders_mapping].split(",").to_h { |mapping| mapping.split("~") }
      reminders_lists = sync_maps.keys
      debug("reminders_lists: #{reminders_lists}", options[:debug])
      merged_reminders = reminders_lists.map { |reminders_list| reminders_in_list(reminders_list) }.flatten
      items = merged_reminders.filter_map do |external_reminder|
        external_id = Reminder.read_external_attribute(external_reminder, Reminder.external_attribute_map[:external_id])
        next if external_id.blank?

        reminder = Reminder.find_or_initialize_by_source(service_name:, external_id:)
        reminder.options = self.class.build_options(reminder.options, service_name)
        reminder.reminder = external_reminder
        reminder.refresh_from_external!(only_modified_dates: true)
      end
      # The reminder list enumeration is always complete (only_modified_dates
      # only narrows attribute reads), so detection runs on every fetch.
      record_source_disappearances!(items, only_modified_dates: false)
      items
    end

    def add_item(external_task, parent_object = nil)
      debug("external_task: #{external_task}, parent_object: #{parent_object}", options[:debug])
      if !options[:pretend]
        target_list = list(external_task)
        return nil if target_list.nil?

        new_reminder = target_list.make(new: :reminder, with_properties: Reminder.from_external(external_task))
        new_reminder_id = new_reminder.id_.get
        update_sync_data(external_task, new_reminder_id)
        new_reminder
      elsif options[:pretend] && options[:verbose]
        "Would have added #{external_task.title} to Reminders"
      end
    end

    def update_item(reminder, external_task)
      debug("reminder: #{reminder}, external_task: #{external_task}", options[:debug])
      item_last_modified = sync_timestamp_for(external_task)
      if options[:max_age_timestamp] && item_last_modified && (item_last_modified < options[:max_age_timestamp])
        "Last modified more than #{options[:max_age]} ago - skipping #{external_task.title}"
      elsif external_task.completed? && reminder.incomplete?
        debug("Complete state doesn't match", options[:debug])
        return "Would have marked #{reminder.title} complete in Reminders" if options[:pretend]

        reminder.mark_complete
        reminder_id = reminder.id_.get
        # If external_task doesn't have our sync ID, this was a title match
        # Add sync ID so future syncs use ID matching instead of title matching
        matched_by_title = external_task.try(:reminders_id).blank?
        update_sync_data(external_task, reminder_id) if matched_by_title || options[:update_ids_for_existing]
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
      return [] unless authorized && reminders_app

      reminders_app.lists.get
    end

    def list_names
      lists.map { |list| list.name.get }
    end

    # Fails closed: an AppleScript failure while enumerating the lists means
    # the detection scope was not fully readable, so the whole detection run
    # is suppressed instead of crashing items_to_sync (#220).
    def readable_list_names
      list_names
    rescue Appscript::CommandError
      []
    end

    def mapped_list_names
      options[:reminders_mapping].split(",").map { |mapping| mapping.split("~").first.strip }
    end

    def reminders_in_list(list_name)
      reminder_list = lists.find { |list| list.name.get == list_name }
      return [] unless reminder_list

      reminder_list.reminders.get
    end

    def list(external_task)
      target_name = project_map.key(external_task.project)
      lists.find { |l| l.name.get == target_name } if target_name
    end

    def project_map
      return {} if options[:reminders_mapping].nil?

      options[:reminders_mapping].split(",").to_h { |mapping| mapping.split("~") }
    end
  end
end
