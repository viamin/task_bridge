# frozen_string_literal: true

module SyncBackfill
  # Backfills mapping rows (RDR #215 `representation_membership` rows)
  # for existing `SyncCollection` memberships so TaskBridge Web sees
  # known cross-system representations as part of the initial seed.
  #
  # Confidence translation follows the publication contract (high →
  # `confirmed`; medium → `inferred`) and the clarified decision under
  # #222: rows at `mapping_confidence: low` (which would map to
  # `tentative`) are withheld from the outbox. Holding them back leaves
  # them identifiable for later manual cleanup via the dry-run summary
  # instead of polluting TaskBridge Web with low-confidence linkages.
  class MappingBaseline
    MAPPING_TYPE = "representation_membership"
    MEMBERSHIP_ROLE = "member"

    CONFIDENCE = {
      "high" => "confirmed",
      "medium" => "inferred"
    }.freeze

    SOURCE = {
      "source_sync_id" => "sync_id_note",
      "title_fallback" => "title_match",
      "manual_backfill" => "manual",
      "created_by_sync" => "created_by_sync"
    }.freeze

    WITHHELD_CONFIDENCE = "low"
    WITHHELD_MAPPING_CONFIDENCE = "tentative"

    def self.run!(dry_run: false, **)
      new(**, dry_run:).run!
    end

    # Same shape as `#run!` but writes nothing. The Runner uses this to
    # preview which mapping rows a live run would emit before publication.
    def self.count_pretend(_now: Time.current)
      counts = empty_counts
      SyncCollection.find_each do |collection|
        counts[:collections_seen] += 1
        members = collection.sync_items.to_a
        counts[:memberships_seen] += members.length
        members.each do |member|
          counts.merge!(classify(collection, member))
        end
      end
      counts
    end

    def self.classify(collection, member)
      return { memberships_skipped_incomplete: 1 } unless eligible?(member)
      return { memberships_withheld_low_confidence: 1 } if withhold?(collection)

      { mappings_emitted: 1 }
    end

    def self.eligible?(member)
      member.persisted? &&
        member.external_id.present? &&
        Outbox::SourceIdentity.for(member)[:service_type].present?
    end

    def self.withhold?(collection)
      [WITHHELD_CONFIDENCE, nil].include?(collection.mapping_confidence)
    end

    def self.empty_counts
      {
        collections_seen: 0,
        memberships_seen: 0,
        mappings_emitted: 0,
        mappings_replayed: 0,
        memberships_withheld_low_confidence: 0,
        memberships_skipped_incomplete: 0
      }
    end

    def initialize(dry_run: false, now: Time.current, logger: nil)
      @dry_run = dry_run
      @now = now
      @logger = logger
      @counts = self.class.empty_counts
    end

    def run!
      SyncCollection.find_each { |collection| baseline_for(collection) }
      counts
    end

    private

    attr_reader :dry_run, :now, :logger, :counts

    def baseline_for(collection)
      counts[:collections_seen] += 1
      members = collection.sync_items.to_a
      counts[:memberships_seen] += members.length

      members.each do |member|
        next counts[:memberships_skipped_incomplete] += 1 unless self.class.eligible?(member)

        publish_for(collection, member)
      end
    end

    def publish_for(collection, member)
      if self.class.withhold?(collection)
        counts[:memberships_withheld_low_confidence] += 1
        logger&.debug(
          "withholding low-confidence mapping for collection #{collection.id} member #{member.external_id}"
        )
        return
      end

      if dry_run
        counts[:mappings_emitted] += 1
        return
      end

      payload = build_payload(collection, member)
      entry = enqueue_or_replay(collection, member, payload)
      if entry.nil?
        counts[:mappings_replayed] += 1
      else
        counts[:mappings_emitted] += 1
      end
    end

    def build_payload(collection, member)
      identity = Outbox::SourceIdentity.for(member)

      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        mapping_type: MAPPING_TYPE,
        observed_at: now.utc.iso8601(6),
        sync_collection: {
          sync_collection_id: collection.id,
          title: collection.title
        },
        member: identity.merge(item_key: member.item_key),
        membership_role: MEMBERSHIP_ROLE,
        mapping_confidence: translate_confidence(collection.mapping_confidence),
        mapping_source: translate_source(collection.mapping_method),
        provenance: {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata || {}
        }
      }
    end

    def translate_confidence(internal_confidence)
      CONFIDENCE.fetch(internal_confidence, WITHHELD_MAPPING_CONFIDENCE)
    end

    def translate_source(internal_method)
      SOURCE.fetch(internal_method, internal_method.to_s)
    end

    def enqueue_or_replay(collection, member, payload)
      identity = Outbox::SourceIdentity.for(member)
      context = {
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id),
        sync_collection_id: collection.id,
        observed_at: now
      }

      Outbox::IsolatedWrite.call("baseline mapping for #{context[:service_instance]}:#{context[:external_id]}") do
        OutboxEntry.enqueue(record_kind: :mapping, payload:, **context)
      end
    end
  end
end
