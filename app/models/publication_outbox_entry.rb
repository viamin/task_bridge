# frozen_string_literal: true

# == Schema Information
#
# Table name: publication_outbox_entries
#
#  id               :integer          not null, primary key
#  idempotency_key  :string           not null
#  record_kind      :string           not null
#  payload          :text             not null
#  status           :string           not null, default: "pending"
#  retry_count      :integer          not null, default: 0
#  error_message    :text
#  service_type     :string
#  service_instance :string
#  observed_at      :datetime
#  delivered_at     :datetime
#  failed_at        :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_publication_outbox_entries_on_idempotency_key          (idempotency_key) UNIQUE
#  index_publication_outbox_entries_on_status_and_created_at    (status, created_at)
#  idx_on_service_instance_status_16c8b627d1                    (service_instance, status)
#
class PublicationOutboxEntry < ApplicationRecord
  STATUSES = %w[pending delivering delivered failed terminal].freeze
  RECORD_KINDS = %w[item observation mapping sync_run].freeze

  # Maximum retries before a row is moved to terminal status.
  MAX_RETRIES = 10

  validates :idempotency_key, presence: true, uniqueness: true
  validates :record_kind, presence: true, inclusion: { in: RECORD_KINDS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :payload_must_be_a_json_object

  scope :pending,    -> { where(status: "pending") }
  scope :delivering, -> { where(status: "delivering") }
  scope :delivered,  -> { where(status: "delivered") }
  scope :failed,     -> { where(status: "failed") }
  scope :terminal,   -> { where(status: "terminal") }

  # Rows eligible for retry: failed rows that have not exceeded MAX_RETRIES.
  scope :retryable, -> { where(status: "failed").where("retry_count < ?", MAX_RETRIES) }

  # Returns rows ready for the next publish attempt, oldest-first.
  scope :publishable, -> { where(status: %w[pending failed]).where("retry_count < ?", MAX_RETRIES).order(:created_at) }

  # Builds an entry from a Publication value object without saving.
  #
  # service_type and service_instance are sourced from payload[:source] for item and
  # observation records, from payload[:member] for mapping records, and from the
  # payload root for sync_run records, so replay-by-service filtering works for
  # every record kind.
  def self.from_record(record)
    payload       = record.to_payload
    identity      = payload[:source] || payload[:member] || {}
    service_type  = identity[:service_type] || payload[:service_type]
    svc_instance  = identity[:service_instance] || payload[:service_instance]
    new(
      idempotency_key: payload[:idempotency_key],
      record_kind: record.class::RECORD_KIND,
      payload: payload_json(payload, payload[:idempotency_key]),
      service_type:,
      service_instance: svc_instance,
      observed_at: payload[:observed_at] || payload[:started_at]
    )
  end

  # The record-level UTF-8 guards cover the free-text fields most likely to
  # carry malformed provider bytes; nested values they do not cover (change
  # transitions, provenance, tags entries) fail JSON generation here. Reject
  # at write time with the offending key instead of surfacing an opaque
  # GeneratorError from deep in serialization.
  def self.payload_json(payload, idempotency_key)
    payload.to_json
  rescue JSON::GeneratorError => e
    raise ArgumentError, "payload for #{idempotency_key} is not serializable: #{e.message}"
  end
  private_class_method :payload_json

  def mark_delivered!
    update!(status: "delivered", delivered_at: Time.current, error_message: nil)
  end

  def mark_failed!(message:)
    new_count = retry_count + 1
    new_status = new_count >= MAX_RETRIES ? "terminal" : "failed"
    update!(
      status: new_status,
      retry_count: new_count,
      failed_at: Time.current,
      error_message: message.to_s.truncate(1000)
    )
  end

  # Records a terminal failure without burning retries: used when the publisher
  # classifies a row rejection as non-retryable (for example a validation
  # error), so the row is kept for operator review and never rescheduled.
  def mark_terminal!(message:)
    update!(
      status: "terminal",
      failed_at: Time.current,
      error_message: message.to_s.truncate(1000)
    )
  end

  def mark_replayed!
    update!(status: "delivered", delivered_at: Time.current, error_message: nil)
  end

  def parsed_payload
    @parsed_payload ||= JSON.parse(payload, symbolize_names: true)
  end

  private

  # The publisher sends the stored payload verbatim, so a row that is not a
  # JSON object could never satisfy the batch contract and must be rejected at
  # write time instead of failing (or crashing) a later publish attempt.
  # Presence is checked here too: JSON.parse accepts malformed UTF-8 byte
  # sequences, and Rails' presence validation raises on them (blank? cannot
  # match an invalid encoding), so encoding is checked before parsing.
  def payload_must_be_a_json_object
    if payload.nil?
      errors.add(:payload, :blank)
    elsif !payload.valid_encoding?
      errors.add(:payload, "must be valid UTF-8")
    else
      parsed = JSON.parse(payload)
      errors.add(:payload, "must be a JSON object") unless parsed.is_a?(Hash)
    end
  rescue JSON::ParserError
    errors.add(:payload, "must be valid JSON")
  end
end
