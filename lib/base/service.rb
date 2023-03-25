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
      raise "not implemented"
    end

    def friendly_name
      raise "not implemented"
    end

    # This method returns a list of strategies that the service supports. There are 3 strategies:
    # * :two_way - the service supports syncing items in both directions using the `sync_with_primary` method
    # * :from_primary - the service supports syncing items from the primary service to the service using the `sync_from_primary` method
    # * :to_primary - the service supports syncing items from the service to the primary service using the `sync_to_primary` method
    def sync_strategies
      raise "not implemented"
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
      service_items = items_to_sync
      paired_items = items_paired_by_sync_id(primary_items, service_items)
      unmatched_primary_items = primary_items - paired_items.flatten
      unmatched_service_items = service_items - paired_items.flatten
      paired_items << items_grouped_by_title(unmatched_primary_items + unmatched_service_items)
      unmatched_primary_items -= paired_items.flatten
      unmatched_service_items -= paired_items.flatten
      item_count = (paired_items.length / 2) + unmatched_primary_items.length + unmatched_service_items.length
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: item_count,
          title: "#{primary_service.class.name} syncing with #{friendly_name}"
        )
      end
      paired_items.each do |pair|
        older_item, newer_item = pair
        if newer_item.instance_of?(primary_service.item_class)
          update_item(older_item, newer_item)
        else
          primary_service.update_item(older_item, newer_item)
        end
        progressbar.increment unless options[:quiet]
      end
      unmatched_primary_items.each do |item|
        add_item(item) unless skip_create?(item)
        progressbar.increment unless options[:quiet]
      end
      unmatched_service_items.each do |item|
        primary_service.add_item(item) unless skip_create?(item)
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{item_count} #{options[:primary]} and #{friendly_name} items" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: item_count }.stringify_keys
    end

    def should_sync?(item_updated_at = nil)
      time_since_last_sync = options[:logger].last_synced(friendly_name, interval: item_updated_at.nil?)
      return true if time_since_last_sync.nil?

      if item_updated_at.present?
        time_since_last_sync < item_updated_at
      else
        time_since_last_sync > min_sync_interval
      end
    end

    def sync_to_primary(_primary_service)
      items = items_to_sync
    end

    private

    # creates items pairs based on sync_ids
    # `items_to_sync` should be defined in the service subclass
    def items_paired_by_sync_id(primary_items, service_items)
      item_pairs = []
      primary_items.each do |primary_item|
        matching_item = service_items.find { |item| item.sync_id == primary_item.id || item.id == primary_item.sync_id }
        item_pairs << [primary_item, matching_item].sort_by(&:updated_at) if matching_item
      end
      item_pairs
    end
    memo_wise :items_paired_by_sync_id

    # creates item groups based on title and notes
    # should be used when items don't have sync_ids
    def items_grouped_by_title(items)
      item_pairs = []
      title_grouping = items.group_by { |item| item.title.downcase.strip }
      title_grouping.each do |_title, title_group|
        if (title_group.length == 2) && (title_group.first.class != title_group.last.class)
          item_pairs << title_group.sort_by(&:updated_at)
        else
          notes_grouping = title_group.group_by { |item| item.notes.downcase.strip }
          notes_grouping.each_value do |notes_group|
            if (notes_group.length == 2) && (notes_group.first.class != notes_group.last.class)
              item_pairs << notes_group.sort_by(&:updated_at)
            elsif notes_group.length > 2
              # in this case, we have multiple items with the same title and notes (probably blank)
              # We can either try to match on other attributes (type dependent) or just treat them as duplicates
              # For now, we'll just treat them as duplicates and randomly pair some up
              service_items = notes_group.select { |item| item.instance_of?(item_class) }
              primary_items = notes_group - service_items
              item_pairs << [primary_items.pop, service_items.pop].sort_by(&:updated_at) while primary_items.length.positive? && service_items.length.positive?
            end
          end
        end
      end
      item_pairs
    end
    memo_wise :items_grouped_by_title

    # the default minimum time we should wait between syncing items
    def min_sync_interval
      raise "not implemented"
    end

    # Defines the conditions under which a task should be not be created,
    # either in the primary_service or in the current service
    def skip_create?(item)
      # Never create new completed items
      return true if item.completed?

      false
    end
  end
end
