# frozen_string_literal: true

module Base
  class Service
    prepend MemoWise
    include Debug

    attr_reader :options

    def initialize(options:)
      @options = options
      @last_sync_data = options[:logger].sync_data_for(friendly_name)
    end

    def item_class
      raise "not implemented in #{self.class.name}"
    end

    def friendly_name
      raise "not implemented in #{self.class.name}"
    end

    # This method returns a list of strategies that the service supports. There are 3 strategies:
    # * :two_way - the service supports syncing items in both directions using the `sync_with_primary` method
    # * :from_primary - the service supports syncing items from the primary service to the service using the `sync_from_primary` method
    # * :to_primary - the service supports syncing items from the service to the primary service using the `sync_to_primary` method
    def sync_strategies
      raise "not implemented in #{self.class.name}"
    end

    # Implements the :two_way sync strategy
    # Steps for a two way sync:
    # 1. Check if enough time has passed since the previous sync attempt
    # 2. Gather the list of items for the current service and the primary service for comparison
    # 3. Pair up matching items in the primary and current services
    # 3a. First try to match items using their sync_id
    # 3b. If no match is found, try to match items using their title (and notes if necessary)
    # 4. With items paired by sync_id, check which item is newer and sync it to the other service
    # 5. For items grouped by title, check how many items are in the group
    # 5a. If there is only a single item, sync it to the other service as a new item
    # 5b. If there are 2 items, sync the newer item to the other service - also update the sync_ids
    # 5c. If there are more than 2 items, match as many attributes as possible between items and treat them as a pair adding sync_ids. (TODO: It might be better to just treat each side as a new item and create duplicates? Maybe there should be a setting for this)
    # 6. Update the sync_log and return results
    def sync_with_primary(primary_service)
      return @last_sync_data unless should_sync?

      primary_items = primary_service.items_to_sync(tags: [friendly_name])
      service_items = items_to_sync(tags: options[:tags])
      item_pairs = paired_items(primary_items, service_items)
      unmatched_primary_items = primary_items - item_pairs.to_a.flatten
      unmatched_service_items = service_items - item_pairs.to_a.flatten
      item_count = item_pairs.length + unmatched_primary_items.length + unmatched_service_items.length
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: item_count,
          title: "#{primary_service.class.name} syncing with #{friendly_name}"
        )
      end
      item_pairs.each do |pair|
        older_item, newer_item = pair
        if newer_item.instance_of?(primary_service.item_class)
          update_item(older_item, newer_item)
        else
          primary_service.update_item(older_item, newer_item)
        end
        progressbar.increment unless options[:quiet]
      end
      unmatched_primary_items.each do |primary_item|
        add_item(primary_item) unless primary_service.skip_create?(primary_item)
        progressbar.increment unless options[:quiet]
      end
      unmatched_service_items.each do |service_item|
        primary_service.add_item(service_item) unless skip_create?(service_item)
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{item_count} #{options[:primary]} and #{friendly_name} items" unless options[:quiet]
      {service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: item_count}.stringify_keys
    end

    # implements the :to_primary sync strategy
    def sync_to_primary(primary_service)
      return @last_sync_data unless should_sync?

      service_items = items_to_sync(tags: options[:tags])
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: service_items.length,
          title: "#{friendly_name} syncing to #{primary_service.friendly_name}"
        )
      end
      service_items.each do |service_item|
        output = if (existing_item = service_item.find_matching_item_in(existing_items(primary_service)))
          if should_sync?(service_item.updated_at)
            primary_service.update_item(existing_item, service_item)
          else
            debug("Skipping sync of #{service_item.title} (should_sync? == false)", options[:debug])
          end
        elsif !service_item.completed?
          primary_service.add_item(service_item)
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{service_items.length} #{friendly_name} items to #{options[:primary]}" unless options[:quiet]
      {service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: service_items.length}.stringify_keys
    end

    # implements the :from_primary sync strategy
    def sync_from_primary(primary_service)
      return @last_sync_data unless should_sync?

      primary_items = primary_service.items_to_sync(tags: [friendly_name])
      service_items = items_to_sync(tags: options[:tags])
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: primary_items.length,
          title: "#{friendly_name} syncing from #{primary_service.friendly_name}"
        )
      end
      primary_items.each do |primary_item|
        output = if (existing_item = primary_item.find_matching_item_in(service_items))
          update_item(existing_item, primary_item)
        else
          add_item(primary_item) unless primary_item.completed?
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{primary_items.length} #{options[:primary]} items to #{friendly_name}" unless options[:quiet]
      {service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: primary_items.length}.stringify_keys
    end

    def should_sync?(item_updated_at = nil)
      time_since_last_sync = options[:logger].last_synced(friendly_name, interval: item_updated_at.nil?)
      return true if time_since_last_sync.nil? || options[:force]

      if item_updated_at.present?
        time_since_last_sync < item_updated_at
      else
        time_since_last_sync > min_sync_interval
      end
    end

    def update_sync_data(existing_item, sync_id, sync_url = nil)
      service_name = friendly_name.underscore
      existing_item.instance_variable_set("@#{service_name}_id", sync_id) if sync_id
      existing_item.instance_variable_set("@#{service_name}_url", sync_url) if sync_url
      existing_item.update_attributes(notes: existing_item.sync_notes)
    end

    def existing_items(service)
      service.items_to_sync(tags: [friendly_name], inbox: true)
    end

    def items_to_sync(*)
      raise "not implemented in #{self.class.name}"
    end

    # Defines the conditions under which a task should be not be created,
    # either in the primary_service or in the current service
    def skip_create?(item)
      # Never create new completed items
      return true if item.completed?

      false
    end

    private

    # find all paired items
    def paired_items(primary_items, service_items)
      paired_items = Set.new
      primary_items.each do |primary_item|
        matching_item = primary_item.find_matching_item_in(service_items)
        paired_items.add([primary_item, matching_item].sort_by(&:updated_at)) if matching_item
      end
      service_items.each do |service_item|
        matching_item = service_item.find_matching_item_in(primary_items)
        paired_items.add([service_item, matching_item].sort_by(&:updated_at)) if matching_item
      end
      paired_items
    end
    memo_wise :paired_items

    # the default minimum time we should wait between syncing items
    def min_sync_interval
      raise "not implemented in #{self.class.name}"
    end
  end
end
