# frozen_string_literal: true

module SyncBackfill
  # Baseline `mapping` outbox rows (#222) for existing SyncCollection
  # memberships, reusing Outbox::MappingEmitter so the confidence and
  # method translation stays centralized (high -> confirmed, medium ->
  # inferred, low -> tentative).
  #
  # Per RDR #215's stated default for its open backfill question
  # (docs/rdr-215-taskbridge-observation-publication-contract.md, "Open
  # Questions"), low-confidence memberships are withheld from publication
  # entirely rather than enqueued as `tentative`: they are only surfaced
  # here, in the backfill summary, for manual cleanup or Web-side review.
  #
  # Idempotent: the mapping idempotency key is derived from the
  # collection's existing mapping_last_observed_at (not the backfill's run
  # time), so rerunning finds the same key per member and leaves the
  # stored row untouched.
  class BaselineMappings
    WITHHELD_CONFIDENCE = "low"

    def self.summary
      new.summary
    end

    def self.run!
      new.run!
    end

    def summary
      tally { |_collection, _members| nil }
    end

    def run!
      tally { |collection, members| Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: observed_at_for(collection)) }
    end

    private

    def tally
      by_confidence = Hash.new(0)
      withheld = []
      incomplete = []
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = eligible_members(collection)
        next incomplete << collection.id if collection.mapping_method.blank? || members.empty?
        next withheld << { id: collection.id, confidence: collection.mapping_confidence } if withheld?(collection)

        by_confidence[collection.mapping_confidence] += members.length
        yield collection, members
      end
      { by_confidence:, withheld:, incomplete: }
    end

    def withheld?(collection)
      collection.mapping_confidence == WITHHELD_CONFIDENCE
    end

    def eligible_members(collection)
      collection.items.select { |item| item.persisted? && item.external_id.present? }
    end

    def observed_at_for(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end
  end
end
