# frozen_string_literal: true

module SyncBackfill
  # Read-only dry run for the baseline backfill (#222): reports planned item
  # snapshots and eligible mappings per service without writing outbox rows or
  # provenance. Counts are derived from Baseline's eligibility rules, the
  # provenance inference, and the emitter's label mapping so the report cannot
  # drift from the real backfill.
  class Preview
    def self.run!
      new.run!
    end

    def run!
      counts = item_counts
      mappings = mapping_counts
      puts "Backfill dry run: items: #{format_counts(counts.fetch(:items))}; mappings: #{format_counts(mappings)}; skipped: #{format_counts(counts.fetch(:skipped))}"
    end

    private

    def item_counts
      Base::SyncItem.find_each.with_object(items: Hash.new(0), skipped: Hash.new(0)) do |item, counts|
        bucket = item.external_id.present? ? :items : :skipped
        service_type = Outbox::SourceIdentity.for(item).fetch(:service_type)
        counts.fetch(bucket)[service_type] += 1
      end
    end

    # Counts eligible members per collection at the confidence a real run
    # would publish — including the label the provenance backfill is about to
    # infer for collections without complete mapping provenance — so the
    # report can never drift from what the backfill publishes.
    def mapping_counts
      SyncCollection.includes(:sync_items).find_each.with_object(Hash.new(0)) do |collection, counts|
        members = SyncBackfill::SourceProvenance.members_in_inference_order(collection)
        confidence = eligible_mapping_confidences[
          SyncBackfill::SourceProvenance.effective_mapping_confidence(collection, peer_notes: peer_notes_for(members))
        ]
        next unless confidence

        member_count = members.count { |item| item.external_id.present? }
        next if member_count.zero?

        counts[confidence] += member_count
      end
    end

    # Derived from Baseline's eligibility rule and the emitter's label mapping
    # so the report can never drift from what the backfill publishes.
    def eligible_mapping_confidences
      Outbox::MappingEmitter::CONFIDENCE.slice(*SyncBackfill::Baseline::ELIGIBLE_MAPPING_CONFIDENCES)
    end

    def peer_notes_for(items)
      items.group_by(&:sync_collection_id).transform_values do |members|
        members.map { |member| [member.id, member.notes] }
      end
    end

    def format_counts(entries)
      return "none" if entries.empty?

      entries.map { |name, count| "#{name}=#{count}" }.join(", ")
    end
  end
end
