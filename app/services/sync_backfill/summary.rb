# frozen_string_literal: true

module SyncBackfill
  class Summary
    def initialize(dry_run:)
      @dry_run = dry_run
      @services = Hash.new(0)
      @confidence = Hash.new(0)
      @skipped = Hash.new(0)
      @snapshots = 0
      @mappings = 0
      @withheld_mappings = 0
    end

    def item(item)
      @services[Outbox::SourceIdentity.for(item)[:service_type]] += 1 if item.external_id.present?
    end

    def snapshot(_service_type)
      @snapshots += 1
    end

    def mapping(confidence)
      @mappings += 1
      @confidence[confidence] += 1
    end

    def withheld_mapping(confidence)
      @withheld_mappings += 1
      @confidence[confidence] += 1
    end

    def skipped_item(_item, reason)
      @skipped[reason] += 1
    end

    def skipped_mapping(_confidence, reason)
      @skipped[reason] += 1
    end

    def to_h
      { dry_run: @dry_run, snapshots: @snapshots, mappings: @mappings,
        withheld_mappings: @withheld_mappings, services: @services, confidence: @confidence, skipped: @skipped }
    end
  end
end
