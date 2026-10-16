# frozen_string_literal: true

module SyncBackfill
  # Read-only dry run for the baseline backfill (#222): reports planned item
  # snapshots and eligible mappings per service without writing outbox rows or
  # provenance. Counts are derived from Baseline's eligibility rules and the
  # emitter's label mapping so the report cannot drift from the real backfill.
  class Preview
    def self.run!
      new.run!
    end

    def run!
      counts = item_counts
      puts "Backfill dry run: items: #{format_counts(counts.fetch(:items))}; mappings: #{format_counts(mapping_counts)}; skipped: #{format_counts(counts.fetch(:skipped))}"
    end

    private

    def item_counts
      Base::SyncItem.find_each.with_object(items: Hash.new(0), skipped: Hash.new(0)) do |item, counts|
        bucket = item.external_id.present? ? :items : :skipped
        service_type = Outbox::SourceIdentity.for(item).fetch(:service_type)
        counts.fetch(bucket)[service_type] += 1
      end
    end

    def mapping_counts
      Base::SyncItem.includes(:sync_collection).find_each.with_object(Hash.new(0)) do |item, counts|
        confidence = eligible_mapping_confidences[item.sync_collection&.mapping_confidence]
        counts[confidence] += 1 if confidence && item.external_id.present?
      end
    end

    # Derived from Baseline's eligibility rule and the emitter's label mapping
    # so the report can never drift from what the backfill publishes.
    def eligible_mapping_confidences
      Outbox::MappingEmitter::CONFIDENCE.slice(*SyncBackfill::Baseline::ELIGIBLE_MAPPING_CONFIDENCES)
    end

    def format_counts(entries)
      return "none" if entries.empty?

      entries.map { |name, count| "#{name}=#{count}" }.join(", ")
    end
  end
end
