# frozen_string_literal: true

module SyncBackfill
  class Summary
    def initialize
      @items = Hash.new(0)
      @mappings = Hash.new(0)
      @skipped = Hash.new(0)
    end

    def record_item(item, skipped:)
      bucket = skipped ? skipped_counts : items
      bucket[service_for(item)] += 1
    end

    def record_mapping(collection, confidence)
      mappings[confidence || collection.mapping_confidence || "unknown"] += 1
    end

    def skip(reason)
      skipped[reason] += 1
    end

    def to_h
      { items: items, mappings: mappings, skipped: skipped }
    end

    private

    attr_reader :items, :mappings, :skipped

    def skipped_counts
      skipped
    end

    def service_for(item)
      Base::Service.service_identifier_for(item.provider)
    end
  end
end
