# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Resolves the effective mapping provenance for every SyncCollection
    # for one backfill run: persisted provenance when present (always the
    # case once SyncBackfill::SourceProvenance has run) and otherwise the
    # same inference that backfill persists, so dry-run previews — which
    # write nothing — still evaluate the provenance a real run stores.
    # Carries the deterministic observed_at mapping rows are keyed on.
    class MappingFacts
      def self.for_all_collections
        SyncCollection.includes(:sync_items).to_h do |collection|
          [collection.id, new(collection).facts]
        end
      end

      def initialize(collection)
        @collection = collection
      end

      def facts
        provenance = effective_provenance
        {
          method: provenance[:method],
          confidence: provenance[:confidence],
          published_confidence: Outbox::MappingEmitter::CONFIDENCE.fetch(provenance[:confidence], provenance[:confidence]),
          published_source: Outbox::MappingEmitter::SOURCE.fetch(provenance[:method], provenance[:method]),
          observed_at: @collection.mapping_last_observed_at || @collection.updated_at || @collection.created_at
        }
      end

      private

      def effective_provenance
        return { method: @collection.mapping_method, confidence: @collection.mapping_confidence } if @collection.mapping_method.present?

        SyncBackfill::SourceProvenance.inferred_provenance_for(@collection)
      end
    end
  end
end
