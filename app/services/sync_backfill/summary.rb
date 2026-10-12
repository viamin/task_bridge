# frozen_string_literal: true

module SyncBackfill
  class Summary
    def initialize
      @items_by_service = Hash.new(0)
      @mappings_by_confidence = Hash.new(0)
      @skipped = Hash.new(0)
    end

    def item(item)
      @items_by_service[::Outbox::SourceIdentity.for(item).fetch(:service_type)] += 1
    end

    def mapping(confidence)
      @mappings_by_confidence[confidence] += 1
    end

    def skip_item(item, reason)
      @skipped["item:#{reason}:#{::Outbox::SourceIdentity.for(item).fetch(:service_type)}"] += 1
    end

    def skip_mapping(_collection, reason)
      @skipped["mapping:#{reason}"] += 1
    end

    def to_h
      { items_by_service: @items_by_service, mappings_by_confidence: @mappings_by_confidence, skipped: @skipped }
    end

    def to_json(*)
      to_h.to_json
    end
  end
end
