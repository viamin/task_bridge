# frozen_string_literal: true

module SyncBackfill
  # Backfills `mapping` outbox rows for existing SyncCollection memberships
  # (#222). Resolves RDR #215's open backfill policy question: `low`
  # confidence (-> `tentative` on the wire) mappings are withheld from
  # publication and surface only in this run's dry-run/summary counts, so a
  # human can review or clean them up before they ever reach TaskBridge
  # Web. `medium`/`high` confidence (-> `inferred`/`confirmed`) memberships
  # are enqueued normally through Outbox::MappingEmitter, which both the
  # live sync pipeline (#219-#221) and this backfill share so published
  # rows have one consistent shape. Idempotent: reruns reuse the same
  # idempotency keys and OutboxEntry.enqueue dedupes on them.
  class MappingObservations
    WITHHELD_CONFIDENCE = "low"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @by_confidence = Hash.new(0)
      @by_service = Hash.new(0)
      @enqueued = 0
      @withheld = 0
      @skipped_incomplete = 0
    end

    def run!
      SyncCollection.includes(:sync_items).find_each { |collection| process(collection) }
      summary
    end

    private

    attr_reader :dry_run

    def process(collection)
      return @skipped_incomplete += 1 if collection.mapping_method.blank?

      members = eligible_members_for(collection)
      return @skipped_incomplete += 1 if members.empty?

      @by_confidence[collection.mapping_confidence] += members.size
      return @withheld += members.size if collection.mapping_confidence == WITHHELD_CONFIDENCE

      emit(collection, members) unless dry_run
      tally(members)
    end

    def eligible_members_for(collection)
      collection.sync_items.select { |item| item.persisted? && item.external_id.present? }
    end

    def emit(collection, members)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || Time.current
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
    end

    def tally(members)
      @enqueued += members.size
      members.each { |member| @by_service[Outbox::SourceIdentity.for(member)[:service_type]] += 1 }
    end

    def summary
      {
        enqueued: @enqueued,
        withheld_low_confidence: @withheld,
        skipped_incomplete: @skipped_incomplete,
        by_confidence: @by_confidence,
        by_service: @by_service
      }
    end
  end
end
