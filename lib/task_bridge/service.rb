module TaskBridge
  class Service
    private

    def get_external_sync_items_for(service_name, services_hash, supported_sync_sources)
      external_sync_items = []
      services_hash.each do |name, service|
        next if name == service_name
        next unless supported_sync_sources.include?(service_name)

        external_sync_items.concat(
          service.sync_items.select { |sync_item| sync_item.tags.include?(service_name) }
        ).map { |external_sync_item| Task.convert_task(external_sync_item) }
      end
      external_sync_items.flatten.compact.uniq
    end
  end
end
