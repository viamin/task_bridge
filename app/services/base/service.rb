# frozen_string_literal: true

module Base
  class Service
    prepend MemoWise
    include Debug
    include GlobalOptions

    def initialize(options: nil)
      self.options = options if options
      @last_sync_data = sync_state&.to_log_hash || self.options[:logger]&.sync_data_for(friendly_name) || {}
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
    def sync_with_primary(primary_service, service_items: nil)
      return @last_sync_data unless should_sync?

      touched_collection_ids = []
      primary_items = primary_service.items_to_sync(tags: [friendly_name])
      service_items ||= items_to_sync(tags: options[:tags])

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
        output = if newer_item.instance_of?(primary_service.item_class)
          update_item(older_item, newer_item)
        else
          primary_service.update_item(older_item, newer_item)
        end
        track_touched_collection!(touched_collection_ids, output) do
          persist_sync_collection_for(*pair)&.id
        end
        progressbar.increment unless options[:quiet]
      end
      unmatched_primary_items.each do |primary_item|
        unless primary_service.skip_create?(primary_item)
          added_item = add_item(primary_item)
          track_touched_collection!(touched_collection_ids, added_item) do
            persist_created_sync_collection_for(primary_item, self, added_item)&.id
          end
        end
        progressbar.increment unless options[:quiet]
      end
      unmatched_service_items.each do |service_item|
        unless skip_create?(service_item)
          added_item = primary_service.add_item(service_item)
          track_touched_collection!(touched_collection_ids, added_item) do
            persist_created_sync_collection_for(service_item, primary_service, added_item)&.id
          end
        end
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{item_count} #{options[:primary]} and #{friendly_name} items" unless options[:quiet]
      sync_result(item_count, touched_collection_ids:)
    end

    # implements the :to_primary sync strategy
    def sync_to_primary(primary_service, service_items: nil)
      return @last_sync_data unless should_sync?

      touched_collection_ids = []
      service_items ||= items_to_sync(tags: options[:tags], only_modified_dates: true)
      existing_primary_items = existing_items(primary_service)
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: service_items.length,
          title: "#{friendly_name} syncing to #{primary_service.friendly_name}"
        )
      end
      service_items.each do |service_item|
        output = if (existing_item = service_item.find_matching_item_in(existing_primary_items))
          if should_sync?(sync_timestamp_for(service_item))
            primary_service.update_item(existing_item, service_item).tap do |result|
              track_touched_collection!(touched_collection_ids, result) do
                persist_sync_collection_for(existing_item, service_item)&.id
              end
            end
          else
            persist_sync_collection_for(existing_item, service_item) unless options[:pretend]
            debug("Skipping sync of #{service_item.title} (should_sync? == false)", options[:debug])
          end
        elsif !service_item.completed?
          primary_service.add_item(service_item).tap do |added_item|
            track_touched_collection!(touched_collection_ids, added_item) do
              persist_created_sync_collection_for(service_item, primary_service, added_item)&.id
            end
          end
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{service_items.length} #{friendly_name} items to #{options[:primary]}" unless options[:quiet]
      sync_result(service_items.length, touched_collection_ids:)
    end

    # implements the :from_primary sync strategy
    def sync_from_primary(primary_service, service_items: nil)
      return @last_sync_data unless should_sync?

      touched_collection_ids = []
      primary_items = primary_service.items_to_sync(tags: [friendly_name])
      service_items ||= items_to_sync(tags: options[:tags])
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: primary_items.length,
          title: "#{friendly_name} syncing from #{primary_service.friendly_name}"
        )
      end
      primary_items.each do |primary_item|
        output = if (existing_item = primary_item.find_matching_item_in(service_items))
          update_item(existing_item, primary_item).tap do |result|
            track_touched_collection!(touched_collection_ids, result) do
              persist_sync_collection_for(existing_item, primary_item)&.id
            end
          end
        elsif !primary_item.completed?
          add_item(primary_item).tap do |added_item|
            track_touched_collection!(touched_collection_ids, added_item) do
              persist_created_sync_collection_for(primary_item, self, added_item)&.id
            end
          end
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{primary_items.length} #{options[:primary]} items to #{friendly_name}" unless options[:quiet]
      sync_result(primary_items.length, touched_collection_ids:)
    end

    def should_sync?(item_updated_at = nil)
      last_successful_at = sync_state&.last_successful_at
      if last_successful_at.nil?
        return true if options[:force]
        return last_synced_before?(item_updated_at) if item_updated_at.present?

        last_sync_interval = options[:logger]&.last_synced(friendly_name, interval: true)
        return true if last_sync_interval.nil?

        return last_sync_interval > min_sync_interval
      end

      return true if options[:force]

      if item_updated_at.present?
        last_successful_at < item_updated_at
      else
        Time.current - last_successful_at > min_sync_interval
      end
    end

    def update_sync_data(existing_item, sync_id, sync_url = nil)
      service_name = service_identifier_for(friendly_name)
      existing_item.instance_variable_set(:"@#{service_name}_id", sync_id) if sync_id
      existing_item.instance_variable_set(:"@#{service_name}_url", sync_url) if sync_url
      existing_item.patch_external_attributes(notes: existing_item.sync_notes)
    end

    def existing_items(service)
      service.items_to_sync(tags: [friendly_name], inbox: true)
    end

    def items_to_sync(*, **)
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

    def last_synced_before?(item_updated_at)
      last_sync_time = options[:logger]&.last_synced(friendly_name)
      return true if last_sync_time.nil?

      last_sync_time < item_updated_at
    end

    def last_successful_sync_at
      sync_state&.last_successful_at || options[:logger]&.last_synced(friendly_name)
    end

    def sync_state
      SyncServiceState.find_by(service_name: friendly_name)
    end

    # find all paired items
    def paired_items(primary_items, service_items)
      paired_items = Set.new
      primary_items.each do |primary_item|
        matching_item = primary_item.find_matching_item_in(service_items)
        paired_items.add([primary_item, matching_item].sort_by { |item| sync_timestamp_for(item) }) if matching_item
      end
      service_items.each do |service_item|
        matching_item = service_item.find_matching_item_in(primary_items)
        paired_items.add([service_item, matching_item].sort_by { |item| sync_timestamp_for(item) }) if matching_item
      end
      paired_items
    end

    def sync_timestamp_for(item)
      item.last_modified || item.updated_at || Time.zone.at(0)
    end

    def persist_sync_collection_for(*items)
      collection_items = items.compact.select do |item|
        item.respond_to?(:sync_collection_id) && item.respond_to?(:sync_collection_id=)
      end
      return if collection_items.length < 2

      existing_collection_ids = collection_items.filter_map(&:sync_collection_id).uniq
      if existing_collection_ids.many?
        debug("Skipping sync collection persistence because items are already linked to different collections: #{existing_collection_ids.join(', ')}")
        return
      end

      collection = if existing_collection_ids.one?
        SyncCollection.find_by(id: existing_collection_ids.first)
      else
        SyncCollection.create!(title: collection_items.filter_map(&:title).first)
      end
      return unless collection

      collection_items.each do |item|
        next if item.sync_collection_id == collection.id

        item.sync_collection_id = collection.id
        item.save! if item.respond_to?(:save!)
      end

      collection
    end

    def persist_created_sync_collection_for(source_item, target_service, created_item)
      target_item = persisted_sync_target_for(target_service, source_item, created_item)
      persist_sync_collection_for(source_item, target_item)
    end

    def persisted_sync_target_for(target_service, source_item, created_item)
      return created_item if created_item.is_a?(Base::SyncItem)

      item_class = target_service.item_class
      return unless item_class.is_a?(Class) && item_class <= Base::SyncItem

      target_service_key = service_identifier_for(target_service.friendly_name)
      external_id = source_item.try(:"#{target_service_key}_id")
      return if external_id.blank?

      item_class.find_or_initialize_by(external_id:).tap do |target_item|
        target_item.title ||= source_item.title if source_item.respond_to?(:title)
        target_item.completed = source_item.completed? if source_item.respond_to?(:completed?)
        target_item.last_modified ||= sync_timestamp_for(source_item)
        target_item.url ||= source_item.try(:"#{target_service_key}_url")
        target_item.save! if target_item.new_record? || target_item.changed?
      end
    end

    def sync_result(items_synced, touched_collection_ids:)
      {
        service: friendly_name,
        last_attempted: options[:sync_started_at],
        last_successful: options[:sync_started_at],
        items_synced:,
        touched_collection_ids: touched_collection_ids.compact.uniq
      }.stringify_keys
    end

    def service_identifier_for(service_name)
      service_name.to_s.underscore.tr(" ", "_")
    end

    def sync_operation_successful?(result)
      !result.is_a?(String)
    end

    def track_touched_collection!(touched_collection_ids, result)
      return if options[:pretend] || !sync_operation_successful?(result)

      touched_collection_ids << yield
    end

    # the default minimum time we should wait between syncing items
    def min_sync_interval
      raise "not implemented in #{self.class.name}"
    end
  end
end
