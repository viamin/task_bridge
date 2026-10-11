# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Enqueues baseline `mapping` rows (RDR #215) for existing
    # SyncCollection memberships (#222). Per the clarified decision on
    # #222, only memberships whose published confidence is `confirmed`
    # (sync-id/created-by-sync evidence) or `inferred` (title-derived)
    # are enqueued; `low`-confidence memberships are withheld from
    # publication and reported in the summary's withheld counts by raw
    # confidence and method so they stay identifiable for later manual
    # cleanup. Memberships that already have a mapping row are skipped,
    # so reruns are safe no-ops.
    class Mappings
      PUBLISHED_CONFIDENCES = %w[confirmed inferred].freeze
      UNKNOWN = "unknown"

      def self.run!(dry_run: false, backfilled_at: Time.current, facts: {})
        new(dry_run:, backfilled_at:, facts:).run!
      end

      def initialize(dry_run:, backfilled_at:, facts:)
        @dry_run = dry_run
        @backfilled_at = backfilled_at
        @facts = facts
        @considered = 0
        @enqueued = 0
        @by_service = Hash.new(0)
        @by_confidence = Hash.new(0)
        @by_method = Hash.new(0)
        @withheld = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def run!
        SyncCollection.includes(:sync_items).find_each do |collection|
          collection.sync_items.each { |member| backfill_membership(collection, member) }
        end
        {
          considered: @considered,
          enqueued: @enqueued,
          by_service: @by_service.sort.to_h,
          by_confidence: @by_confidence.sort.to_h,
          by_method: @by_method.sort.to_h,
          withheld: @withheld.sort.to_h,
          skipped: @skipped.sort.to_h
        }
      end

      private

      def backfill_membership(collection, member)
        @considered += 1
        if member.external_id.blank?
          @skipped["missing_external_id"] += 1
          return
        end

        facts = @facts.fetch(collection.id, {})
        identity = SyncBackfill::Baseline.identity_for(member)
        if withhold?(facts)
          @withheld[facts[:confidence].presence || UNKNOWN] += 1
          return
        end
        if already_backfilled?(collection, identity)
          @skipped["already_backfilled"] += 1
          return
        end

        @enqueued += 1
        @by_service[identity[:service_type]] += 1
        @by_confidence[facts[:published_confidence]] += 1
        @by_method[facts[:method].presence || UNKNOWN] += 1
        return if @dry_run

        Outbox::MappingEmitter.emit_for_members(
          collection,
          members: [member],
          observed_at: facts[:observed_at],
          provenance_extras: {
            "detected_by" => ItemPayload::DETECTED_BY,
            "backfilled_at" => @backfilled_at.utc.iso8601(6)
          }
        )
      end

      # Unknown/nil confidences publish unknown enum values (RDR #215 v1
      # consumers must ignore them), but the backfill stays conservative:
      # withhold anything that is not explicitly confirmed or inferred.
      def withhold?(facts)
        PUBLISHED_CONFIDENCES.exclude?(facts[:published_confidence])
      end

      def already_backfilled?(collection, identity)
        existing_memberships.include?([collection.id, identity[:service_instance], identity[:external_id]])
      end

      def existing_memberships
        @existing_memberships ||= OutboxEntry.where(record_kind: "mapping")
                                             .pluck(:sync_collection_id, :service_instance, :external_id).to_set
      end
    end
  end
end
