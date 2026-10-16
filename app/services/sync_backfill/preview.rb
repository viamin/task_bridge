# frozen_string_literal: true

module SyncBackfill
  class Preview
    ELIGIBLE_MAPPING_CONFIDENCES = {
      "high" => "confirmed",
      "medium" => "inferred"
    }.freeze

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
        confidence = ELIGIBLE_MAPPING_CONFIDENCES[item.sync_collection&.mapping_confidence]
        counts[confidence] += 1 if confidence && item.external_id.present?
      end
    end

    def format_counts(entries)
      entries.map { |name, count| "#{name}=#{count}" }.join(", ")
    end
  end
end
