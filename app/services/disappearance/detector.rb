# frozen_string_literal: true

module Disappearance
  # Detects source representations that vanished from a successful,
  # complete fetch and enqueues tombstone observations into the outbox for
  # TaskBridge Web (RDR #215 "Deletes and Tombstones", issue #220).
  #
  # Detection is conservative by construction:
  # - absence from a filtered, incremental, or partial fetch never produces
  #   a tombstone (each adapter declares its Disappearance::Strategy);
  # - a failed or unauthorized source never produces tombstones;
  # - local sync_items rows are never deleted — the outbox observation is
  #   the only side effect, and a marker in source_metadata keeps repeated
  #   runs from re-emitting the same state (idempotency).
  class Detector
    attr_reader :service, :observed_items, :sync_run_id, :observed_at, :complete_fetch

    class << self
      def record!(service:, observed_items:, complete_fetch:, observed_at: Time.current)
        sync_run_id = sync_run_id_for(service, at: observed_at)
        new(service:, observed_items:, sync_run_id:, observed_at:, complete_fetch:).record!
      end

      private

      # RDR #215 sync-run scope, e.g. "sync-run-20260814T192000Z-asana".
      def sync_run_id_for(service, at:)
        identifier = Base::Service.service_identifier_for(service.service_name)
        "sync-run-#{at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{identifier}"
      end
    end

    def initialize(service:, observed_items:, sync_run_id:, observed_at:, complete_fetch:)
      @service = service
      @observed_items = Array(observed_items)
      @sync_run_id = sync_run_id
      @observed_at = observed_at
      @complete_fetch = complete_fetch
    end

    # Returns the OutboxEntry rows enqueued by this call (empty when
    # detection is suppressed or every candidate was already recorded).
    def record!
      return [] unless eligible?

      observed_ids = observed_external_ids
      persisted_items.find_each.filter_map do |item|
        record_item(item) if missing?(item, observed_ids)
      end
    end

    private

    def eligible?
      return false if service.options[:pretend]
      return false if strategy.disabled?
      return false unless complete_fetch
      return false if service.respond_to?(:authorized) && service.authorized == false
      return false unless service.deletion_detection_scope_available?

      true
    end

    def strategy
      service.deletion_detection_strategy
    end

    def missing?(item, observed_ids)
      item.external_id.present? && !observed_ids.include?(item.external_id)
    end

    def persisted_items
      service.item_class.where(source_service_name: service.service_name)
    end

    # Sub-items are observed alongside their parents even though the fetch
    # only returns top-level items (e.g. Asana subtasks), so they count as
    # observed and are never tombstoned while their parent is present.
    def observed_external_ids
      observed_items.each_with_object(Set.new) { |item, ids| collect_external_ids(item, ids) }
    end

    def collect_external_ids(item, ids)
      ids << item.external_id if item.external_id.present?
      Array(item.try(:sub_items)).each { |sub_item| collect_external_ids(sub_item, ids) }
    end

    def record_item(item)
      return unless service.disappearance_candidate?(item)

      finding = finding_for(item)
      return if finding.nil?
      return if recorded_state_for(item) == finding.state

      enqueue_tombstone(item, finding).tap { mark_recorded(item, finding) }
    end

    def finding_for(item)
      return Finding.new(state: strategy.state, confidence: strategy.confidence) if strategy.full_list_absence?

      service.verify_missing_item(item)
    end

    def enqueue_tombstone(item, finding)
      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :observation,
        event_type: "deleted",
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at,
        observed_at:,
        payload: payload_for(item, finding, identity)
      )
    end

    def payload_for(item, finding, identity)
      {
        "contract_version" => OutboxEntry::PAYLOAD_VERSION,
        "event_type" => "deleted",
        "observed_at" => observed_at.utc.iso8601(6),
        "item_key" => item.item_key,
        "source" => source_payload(identity),
        "last_known" => last_known_payload(item),
        "is_deleted" => Disappearance::States.deletion?(finding.state),
        "disappearance_state" => finding.state,
        "provenance" => provenance_payload(finding)
      }
    end

    def source_payload(identity)
      identity.compact
    end

    def last_known_payload(item)
      {
        "title" => item.title,
        "status" => item.completed? ? "completed" : "open",
        "last_observed_at" => item.last_observed_at&.utc&.iso8601(6),
        "source_updated_at" => item.source_updated_at&.utc&.iso8601(6)
      }.compact
    end

    def provenance_payload(finding)
      {
        "detected_by" => strategy.detected_by,
        "confidence" => finding.confidence,
        "detection_strategy" => strategy.mode.to_s,
        "sync_run_id" => sync_run_id
      }.merge(finding.detail || {})
    end

    def recorded_state_for(item)
      marker = marker_for(item)
      marker.is_a?(Hash) ? marker["state"] : nil
    end

    def mark_recorded(item, finding)
      marker = {
        "state" => finding.state,
        "observed_at" => observed_at.utc.iso8601(6),
        "sync_run_id" => sync_run_id
      }
      # update_columns skips callbacks so recording a disappearance never
      # bumps last_observed_at — the item was, by definition, not observed.
      item.update_columns(
        source_metadata: source_metadata_hash(item).merge(Base::SyncItem::DISAPPEARANCE_MARKER_KEY => marker),
        updated_at: observed_at
      )
    end

    def marker_for(item)
      source_metadata_hash(item)[Base::SyncItem::DISAPPEARANCE_MARKER_KEY]
    end

    # Legacy rows may hold non-hash source_metadata; treat those as empty.
    def source_metadata_hash(item)
      item.source_metadata.is_a?(Hash) ? item.source_metadata : {}
    end
  end
end
