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
  REQUIRED_STRING_FIELDS = %i[idempotency_key record_kind status service_type service_instance].freeze
  OPTIONAL_STRING_FIELDS = %i[error_message].freeze

  # EachValidator short-circuits through value.blank? (and uniqueness and
  # inclusion reach it before any custom validator can reject the value), so
  # every built-in string validation is gated behind an encoding check that
  # records the error itself.
  validates :idempotency_key, uniqueness: true, if: -> { string_encoding_valid?(:idempotency_key) }
  validates :record_kind, inclusion: { in: RECORD_KINDS }, if: -> { string_encoding_valid?(:record_kind) }
  validates :status, inclusion: { in: STATUSES }, if: -> { string_encoding_valid?(:status) }
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :validate_string_fields
  validate :validate_observed_at
  validate :payload_must_be_a_json_object
  validate :validate_payload_contract_version
  validate :validate_payload_idempotency_key

  scope :pending,    -> { where(status: "pending") }
  scope :delivering, -> { where(status: "delivering") }
  scope :delivered,  -> { where(status: "delivered") }
  scope :failed,     -> { where(status: "failed") }
  scope :terminal,   -> { where(status: "terminal") }

  # Rows eligible for retry: failed rows that have not exceeded MAX_RETRIES.
  scope :retryable, -> { where(status: "failed").where("retry_count < ?", MAX_RETRIES) }

  # Returns rows ready for the next publish attempt, oldest-first.
  scope :publishable, -> { where(status: %w[pending failed]).where("retry_count < ?", MAX_RETRIES).order(:created_at, :id) }

  # Builds an entry from a Publication value object without saving.
  #
  # service_type and service_instance are sourced from payload[:source] for item and
  # observation records, from payload[:member] for mapping records, and from the
  # payload root for sync_run records, so replay-by-service filtering works for
  # every record kind.
  def self.from_record(record)
    kind    = record_kind!(record)
    payload = record.to_payload
    # A non-hash payload (nil, array, scalar) crashes the identity extraction
    # below with an opaque TypeError or NoMethodError, so like record_kind! it
    # fails here with a clear error naming the problem instead.
    raise ArgumentError, "to_payload must return a hash" unless payload.is_a?(Hash)

    identity = payload_identity(payload)

    idempotency_key = fetch_required_payload_string!(payload, :idempotency_key)
    validate_payload_contract_version!(payload, idempotency_key)
    service_type     = preferred_payload_value(identity, payload, :service_type)
    service_instance = preferred_payload_value(identity, payload, :service_instance)
    observed_at      = observed_at_value(payload)
    payload          = canonical_payload(payload)

    validate_extracted_provenance!(
      service_type:,
      service_instance:,
      observed_at:,
      idempotency_key:
    )

    new(
      idempotency_key:,
      record_kind: kind,
      payload: payload_json(payload, idempotency_key),
      service_type:,
      service_instance:,
      observed_at: Publication::Timestamp.format(observed_at)
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

  # published_at is per-attempt transport metadata. The outbox stores the
  # canonical record payload so retries can stamp a fresh published_at without
  # mutating any persisted record facts.
  def self.canonical_payload(payload)
    payload.except(:published_at, "published_at")
  end
  private_class_method :canonical_payload

  # The record-level UTF-8 guards cover the string fields most likely to
  # carry malformed provider bytes; nested values they do not cover
  # (provenance, change from/to transitions, source_metadata) fail
  # JSON generation here. Reject at write time with the offending key
  # instead of surfacing an opaque GeneratorError from deep in serialization.
  # NestingError (a ParserError subclass) is rescued too: a deeply nested
  # source_metadata exceeds the JSON generation depth limit.
  def self.payload_json(payload, idempotency_key)
    payload.to_json
  rescue JSON::GeneratorError, JSON::NestingError => e
    raise ArgumentError, "payload for #{idempotency_key} is not serializable: #{e.message}"
  end
  private_class_method :payload_json

  # The outbox depends on extracted provenance for filtering, replay, and
  # ordering; a row missing these fields is malformed even if the DB schema
  # allows nils, so it is rejected before construction instead of persisting a
  # partially usable contract row.
  def self.validate_extracted_provenance!(service_type:, service_instance:, observed_at:, idempotency_key:)
    Publication::Utf8.validate_fields!(
      "payload service_type" => service_type,
      "payload service_instance" => service_instance,
      "payload observed_at" => observed_at
    )

    {
      service_type:,
      service_instance:
    }.each do |field, value|
      next if value.is_a?(String) && value.present?

      raise ArgumentError, "payload #{field} is required for #{idempotency_key}"
    end

    raise ArgumentError, "payload observed_at is required for #{idempotency_key}" if observed_at.blank?

    Publication::Timestamp.validate!(observed_at)
  rescue ArgumentError => e
    raise ArgumentError, "payload observed_at is invalid for #{idempotency_key}: #{e.message}" if e.message.start_with?("invalid ISO 8601 timestamp")

    raise
  end
  private_class_method :validate_extracted_provenance!

  def self.fetch_required_payload_string!(payload, field)
    value = Publication::HashAccess.fetch(payload, field)
    Publication::Utf8.validate_fields!("payload #{field}" => value)
    return value if value.is_a?(String) && value.present?

    raise ArgumentError, "payload #{field} is required"
  end
  private_class_method :fetch_required_payload_string!

  def self.validate_payload_contract_version!(payload, idempotency_key)
    version = Publication::HashAccess.fetch(payload, :contract_version)
    return if version.is_a?(Integer) && version == Publication::CONTRACT_VERSION

    raise ArgumentError, "payload contract_version must be #{Publication::CONTRACT_VERSION} for #{idempotency_key}"
  end
  private_class_method :validate_payload_contract_version!

  # A blank-but-present value is still malformed contract data and must not
  # silently fall back to a secondary location. Fallback only when the primary
  # key is absent entirely.
  def self.preferred_payload_value(primary, fallback, field)
    return Publication::HashAccess.fetch(primary, field) if Publication::HashAccess.key?(primary, field)

    Publication::HashAccess.fetch(fallback, field)
  end
  private_class_method :preferred_payload_value

  # source/member provenance sections are mutually exclusive by record kind.
  # If one key is present, a nil or wrong-typed value must fail instead of
  # silently falling through to the other section and extracting the wrong
  # service provenance.
  def self.payload_identity(payload)
    return required_payload_hash!(payload, :source) if Publication::HashAccess.key?(payload, :source)
    return required_payload_hash!(payload, :member) if Publication::HashAccess.key?(payload, :member)

    {}
  end
  private_class_method :payload_identity

  def self.required_payload_hash!(payload, field)
    value = Publication::HashAccess.fetch(payload, field)
    return value if value.is_a?(Hash)

    raise ArgumentError, "payload #{field} must be a hash when present"
  end
  private_class_method :required_payload_hash!

  # SyncRunSummary uses started_at as the outbox ordering timestamp. Records
  # that expose observed_at must not mask a blank/invalid value by falling back
  # to started_at; only a missing observed_at key may do that.
  def self.observed_at_value(payload)
    return Publication::HashAccess.fetch(payload, :observed_at) if Publication::HashAccess.key?(payload, :observed_at)

    Publication::HashAccess.fetch(payload, :started_at)
  end
  private_class_method :observed_at_value

  def mark_delivered!
    with_transition_lock(:mark_delivered!) do
      ensure_not_delivered_or_terminal!(:mark_delivered!)
      update!(status: "delivered", delivered_at: Time.current, failed_at: nil, error_message: nil)
    end
  end

  def mark_failed!(message:)
    with_transition_lock(:mark_failed!) do
      ensure_not_delivered_or_terminal!(:mark_failed!)
      new_count = retry_count + 1
      new_status = new_count >= MAX_RETRIES ? "terminal" : "failed"
      update!(
        status: new_status,
        retry_count: new_count,
        delivered_at: nil,
        failed_at: Time.current,
        error_message: sanitized_message(message)
      )
    end
  end

  # Records a terminal failure without burning retries: used when the publisher
  # classifies a row rejection as non-retryable (for example a validation
  # error), so the row is kept for operator review and never rescheduled.
  def mark_terminal!(message:)
    with_transition_lock(:mark_terminal!) do
      ensure_not_delivered_or_terminal!(:mark_terminal!)
      update!(
        status: "terminal",
        delivered_at: nil,
        failed_at: Time.current,
        error_message: sanitized_message(message)
      )
    end
  end

  # Recording a failure must never fail itself: a message carrying malformed
  # bytes (remote response text that slipped past sanitization) is scrubbed so
  # it satisfies the UTF-8 validation instead of raising RecordInvalid.
  def sanitized_message(message)
    Publication::Utf8.sanitize(message.to_s).truncate(1000)
  end
  private :sanitized_message

  def mark_replayed!
    with_transition_lock(:mark_replayed!) do
      ensure_not_delivered_or_terminal!(:mark_replayed!)
      update!(status: "delivered", delivered_at: Time.current, failed_at: nil, error_message: nil)
    end
  end

  def parsed_payload
    raise TypeError, "payload must be a string" unless payload.is_a?(String)

    return @parsed_payload if defined?(@parsed_payload_source) && @parsed_payload_source == payload

    @parsed_payload_source = payload.dup
    @parsed_payload = deep_freeze_json_value(JSON.parse(payload, symbolize_names: true))
  end

  private

  # parsed_payload is cached for repeated publisher validation, so it must be
  # immutable: mutating the returned hash would otherwise change what the
  # publisher sends without changing the stored JSON payload itself.
  def deep_freeze_json_value(value)
    case value
    when Array
      value.each { |item| deep_freeze_json_value(item) }
    when Hash
      value.each_value { |nested| deep_freeze_json_value(nested) }
    end

    value.freeze
  end

  # terminal rows are already a final operator-visible outcome. Allowing later
  # callers to mutate them would let duplicate workers overwrite the failure
  # that intentionally stopped further retries. delivered rows are also final
  # for downgrade paths: a late timeout or validation path must not move a row
  # back out of successful delivery once another worker has finished it.
  def ensure_not_delivered_or_terminal!(operation)
    return unless %w[delivered terminal].include?(status)

    raise ArgumentError, "#{operation} cannot transition a #{status} outbox row"
  end

  def with_transition_lock(operation)
    raise ActiveRecord::RecordNotSaved, "#{operation} requires a persisted outbox row" unless persisted?

    with_lock do
      reload
      yield
    end
  rescue ActiveRecord::RecordNotFound
    raise ActiveRecord::RecordNotSaved, "#{operation} requires a persisted outbox row"
  end

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

  # The outbox orders and filters rows by observed_at; a row without that
  # timestamp is malformed even if it was built outside .from_record.
  def validate_observed_at
    raw_value = validating_raw_observed_at? ? observed_at_before_type_cast : observed_at
    raw_value = observed_at if raw_value.blank?
    return errors.add(:observed_at, :blank) if raw_value.blank?

    Publication::Timestamp.validate!(raw_value)
  rescue ArgumentError => e
    errors.add(:observed_at, e.message)
  end

  def validating_raw_observed_at?
    new_record? || will_save_change_to_observed_at?
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
    elsif !payload.is_a?(String)
      errors.add(:payload, "must be a string")
    elsif !payload.valid_encoding?
      errors.add(:payload, "must be valid UTF-8")
    else
      parsed = JSON.parse(payload)
      errors.add(:payload, "must be a JSON object") unless parsed.is_a?(Hash)
    end
  rescue JSON::ParserError
    errors.add(:payload, "must be valid JSON")
  end

  def validate_payload_contract_version
    return if errors.key?(:payload)

    version = parsed_payload["contract_version"] || parsed_payload[:contract_version]
    return if version.is_a?(Integer) && version == Publication::CONTRACT_VERSION

    errors.add(:payload, "contract_version must be #{Publication::CONTRACT_VERSION}")
  rescue JSON::ParserError, TypeError
    nil
  end

  # The outbox row key and payload key must agree: response reconciliation uses
  # the row key, while retries resend the stored payload. Persisting a mismatch
  # would only fail later in the publisher after the bad row was already saved.
  def validate_payload_idempotency_key
    return if errors.key?(:payload) || errors.key?(:idempotency_key)

    payload_key = parsed_payload["idempotency_key"] || parsed_payload[:idempotency_key]
    return if payload_key == idempotency_key

    errors.add(:payload, "idempotency_key must match the outbox row")
  rescue JSON::ParserError, TypeError
    nil
  end
end
