# frozen_string_literal: true

# == Schema Information
#
# Table name: outbox_entries
#
#  id                 :integer          not null, primary key
#  attempts           :integer          default(0), not null
#  created_at         :datetime         not null
#  error_class        :string
#  error_message      :text
#  event_type         :string
#  external_id        :string
#  idempotency_key    :string           not null
#  next_retry_at      :datetime
#  observed_at        :datetime         not null
#  payload            :json             not null
#  payload_version    :integer          default(1), not null
#  published_at       :datetime
#  record_kind        :string           not null
#  service_instance   :string
#  service_type       :string           not null
#  source_updated_at  :datetime
#  status             :string           default("pending"), not null
#  sync_collection_id :integer
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_outbox_entries_on_idempotency_key      (idempotency_key) UNIQUE
#  index_outbox_entries_on_observed_at          (observed_at)
#  index_outbox_entries_on_source_identity      (service_type,service_instance,external_id)
#  index_outbox_entries_on_sync_collection_id   (sync_collection_id)
#  index_outbox_entries_pending_publication     (observed_at) WHERE (status = 'pending')
#
# Foreign Keys
#
#  sync_collection_id  (sync_collection_id => sync_collections.id)
#
# Local outbox for normalized observations and current-state snapshots bound
# for TaskBridge Web (docs/rdr-215-taskbridge-observation-publication-contract.md).
# The outbox is a bounded queue, not an archive: TaskBridge Web owns durable
# history, so delivered rows and reviewed terminal failures are pruned after
# the windows in task_bridge.outbox.retention.
class OutboxEntry < ApplicationRecord
  extend GlobalOptions

  RECORD_KINDS = %w[item observation mapping sync_run].freeze
  OBSERVATION_EVENT_TYPES = %w[snapshot_seen source_changed deleted].freeze
  STATUSES = %w[pending delivered failed].freeze
  PAYLOAD_VERSION = 1

  ENQUEUE_CONTEXT_KEYS = %i[
    service_type
    service_instance
    external_id
    event_type
    sync_collection_id
    sync_run_id
    source_updated_at
    observed_at
    payload_version
    idempotency_key
  ].freeze

  RETRY_BACKOFF_BASE = 1.minute
  RETRY_BACKOFF_MAX = 1.hour
  RETRY_JITTER_FRACTION = 0.25

  # The canonical record payload and its identity must stay immutable across
  # retries (RDR #215); only delivery state may change after insert.
  attr_readonly :idempotency_key, :record_kind, :payload

  belongs_to :sync_collection, optional: true

  validates :idempotency_key, presence: true
  validates :record_kind, inclusion: { in: RECORD_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :service_type, :observed_at, :payload, presence: true
  validates :payload_version, numericality: { only_integer: true, greater_than: 0 }
  validates :event_type,
            presence: true,
            inclusion: { in: OBSERVATION_EVENT_TYPES },
            if: :observation?

  scope :pending, -> { where(status: "pending") }
  scope :delivered, -> { where(status: "delivered") }
  scope :failed, -> { where(status: "failed") }
  # Pending rows the publisher may send now: best-effort FIFO by observed_at,
  # honoring retry backoff. Not a correctness constraint — the RDR evaluates
  # rows independently and supports partial success.
  scope :due_for_publication, lambda { |now = Time.current|
    pending.where(next_retry_at: nil).or(pending.where(next_retry_at: ..now))
  }

  class << self
    # Enqueues a normalized record for publication, independent of publication
    # itself, so sync success is never coupled to TaskBridge Web availability.
    # Idempotent: re-enqueueing an existing idempotency key returns the stored
    # row untouched, so rerunning a sync does not duplicate an observation.
    # Strict no-op (returns nil) in --pretend mode: pretend runs never write
    # outbox rows; preview/export surfaces land with #222 instead.
    #
    # `context` carries the source identity and run-scoped context
    # (ENQUEUE_CONTEXT_KEYS) future producers (#219-#222) supply: per-item
    # rows pass service identity plus event_type; mapping rows pass
    # sync_collection_id; sync-run rows pass sync_run_id.
    def enqueue(record_kind:, payload:, **context)
      return if options[:pretend]

      attributes = enqueue_attributes(record_kind:, payload:, **context)
      # The unique index on idempotency_key is the dedupe mechanism: a
      # concurrent insert races into RecordNotUnique and falls back to the
      # stored row, so the dedupe path never depends on the payload matching.
      create_or_find_by(idempotency_key: attributes.fetch(:idempotency_key)) do |entry|
        entry.assign_attributes(attributes)
      end
    end

    private

    def enqueue_attributes(record_kind:, payload:, **context)
      validate_enqueue_context!(context)
      observed_at = context.fetch(:observed_at, Time.current)
      {
        idempotency_key: context.fetch(:idempotency_key) do
          Outbox::IdempotencyKey.for(record_kind:, observed_at:, **context)
        end,
        record_kind: record_kind.to_s,
        payload:,
        payload_version: context.fetch(:payload_version, PAYLOAD_VERSION),
        service_type: context.fetch(:service_type),
        service_instance: context[:service_instance],
        external_id: context[:external_id],
        event_type: context[:event_type],
        sync_collection_id: context[:sync_collection_id],
        observed_at:,
        source_updated_at: context[:source_updated_at]
      }
    end

    def validate_enqueue_context!(context)
      unknown_keys = context.keys - ENQUEUE_CONTEXT_KEYS
      return if unknown_keys.empty?

      raise ArgumentError, "unknown enqueue context keys: #{unknown_keys.join(', ')}"
    end
  end

  def observation?
    record_kind == "observation"
  end

  def pending?
    status == "pending"
  end

  def delivered?
    status == "delivered"
  end

  def failed?
    status == "failed"
  end

  # Marks the row delivered only after TaskBridge Web accepts (or replays) it.
  def mark_delivered!(at: Time.current)
    update!(status: "delivered", published_at: at, next_retry_at: nil,
            error_class: nil, error_message: nil)
  end

  # Records one failed publication attempt. Retryable failures stay pending
  # with exponential backoff and jitter; terminal failures move to `failed`
  # for operator review until the retention window prunes them.
  def record_publication_failure!(error_class:, error_message:, retryable: true, now: Time.current)
    attributes = {
      attempts: attempts + 1,
      error_class: error_class.to_s.presence,
      error_message: error_message.to_s.presence
    }
    if retryable
      attributes[:status] = "pending"
      attributes[:next_retry_at] = now + backoff_interval
    else
      attributes[:status] = "failed"
      attributes[:next_retry_at] = nil
    end
    update!(attributes)
  end

  # Manual or scripted replay for terminal failures (RDR #215 failure semantics).
  def retry!
    update!(status: "pending", next_retry_at: nil, error_class: nil, error_message: nil)
  end

  private

  def backoff_interval
    interval = [RETRY_BACKOFF_BASE * (2**attempts), RETRY_BACKOFF_MAX].min
    interval + (interval * rand * RETRY_JITTER_FRACTION)
  end
end
