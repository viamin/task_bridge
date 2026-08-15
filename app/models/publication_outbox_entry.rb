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
  validates :payload, presence: true
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
      payload: payload.to_json,
      service_type:,
      service_instance: svc_instance,
      observed_at: payload[:observed_at] || payload[:started_at]
    )
  end

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
  def payload_must_be_a_json_object
    return if payload.blank?

    parsed = JSON.parse(payload)
    errors.add(:payload, "must be a JSON object") unless parsed.is_a?(Hash)
  rescue JSON::ParserError
    errors.add(:payload, "must be valid JSON")
  end
end
