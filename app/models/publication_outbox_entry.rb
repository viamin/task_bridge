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

  # Presence for these columns is enforced by validate_string_fields instead of
  # validates :presence because blank? raises on invalid byte sequences; the
  # encoding check must run first or valid?/save crash with an opaque
  # ArgumentError instead of returning validation errors.
  REQUIRED_STRING_FIELDS = %i[idempotency_key record_kind status].freeze
  OPTIONAL_STRING_FIELDS = %i[service_type service_instance error_message].freeze

  # EachValidator short-circuits through value.blank? (and uniqueness and
  # inclusion reach it before any custom validator can reject the value), so
  # every built-in string validation is gated behind an encoding check that
  # records the error itself.
  validates :idempotency_key, uniqueness: true, if: -> { string_encoding_valid?(:idempotency_key) }
  validates :record_kind, inclusion: { in: RECORD_KINDS }, if: -> { string_encoding_valid?(:record_kind) }
  validates :status, inclusion: { in: STATUSES }, if: -> { string_encoding_valid?(:status) }
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :validate_string_fields
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
    kind             = record_kind!(record)
    payload          = record.to_payload
    identity         = payload[:source] || payload[:member] || {}
    service_type     = identity[:service_type] || payload[:service_type]
    service_instance = identity[:service_instance] || payload[:service_instance]
    new(
      idempotency_key: payload[:idempotency_key],
      record_kind: kind,
      payload: payload_json(payload, payload[:idempotency_key]),
      service_type:,
      service_instance:,
      observed_at: payload[:observed_at] || payload[:started_at]
    )
  end

  # A wrong-typed record (anything without to_payload/RECORD_KIND) would
  # otherwise crash with an opaque NameError or NoMethodError; the batch and
  # the publisher guard the same record interface, so the outbox does too.
  def self.record_kind!(record)
    raise ArgumentError, "record must respond to to_payload" unless record.respond_to?(:to_payload)

    kind = record.class::RECORD_KIND
    raise ArgumentError, "unknown record_kind: #{kind}" unless RECORD_KINDS.include?(kind)

    kind
  rescue NameError
    raise ArgumentError, "record class must define RECORD_KIND"
  end
  private_class_method :record_kind!

  # The record-level UTF-8 guards cover the string fields most likely to
  # carry malformed provider bytes; nested values they do not cover
  # (provenance, parent, change from/to transitions, source_metadata) fail
  # JSON generation here. Reject at write time with the offending key
  # instead of surfacing an opaque GeneratorError from deep in serialization.
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
      error_message: sanitized_message(message)
    )
  end

  # Records a terminal failure without burning retries: used when the publisher
  # classifies a row rejection as non-retryable (for example a validation
  # error), so the row is kept for operator review and never rescheduled.
  def mark_terminal!(message:)
    update!(
      status: "terminal",
      failed_at: Time.current,
      error_message: sanitized_message(message)
    )
  end

  # Recording a failure must never fail itself: a message carrying malformed
  # bytes (remote response text that slipped past sanitization) is scrubbed so
  # it satisfies the UTF-8 validation instead of raising RecordInvalid.
  def sanitized_message(message)
    Publication::Utf8.sanitize(message.to_s).truncate(1000)
  end
  private :sanitized_message

  def mark_replayed!
    update!(status: "delivered", delivered_at: Time.current, error_message: nil)
  end

  def parsed_payload
    @parsed_payload ||= JSON.parse(payload, symbolize_names: true)
  end

  private

  # Encoding is verified for every string column first — blank? raises on
  # invalid byte sequences, so presence runs only on values that passed the
  # encoding check. This mirrors payload_must_be_a_json_object: a malformed
  # value must produce a validation error, not an opaque ArgumentError crash
  # from valid?/save.
  def validate_string_fields
    (REQUIRED_STRING_FIELDS + OPTIONAL_STRING_FIELDS).each do |field|
      value = public_send(field)
      errors.add(field, "must be valid UTF-8") if value.is_a?(String) && !value.valid_encoding?
    end

    REQUIRED_STRING_FIELDS.each do |field|
      next if errors.key?(field)

      errors.add(field, :blank) if public_send(field).blank?
    end
  end

  def string_encoding_valid?(field)
    value = public_send(field)
    return true unless value.is_a?(String)

    value.valid_encoding?
  end

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
