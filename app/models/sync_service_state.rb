# frozen_string_literal: true

class SyncServiceState < ApplicationRecord
  TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%6N%:z"

  validates :service_name, presence: true, uniqueness: true

  def self.record_summary!(summary)
    normalized_summary = summary.stringify_keys
    state = find_or_initialize_by(service_name: normalized_summary.fetch("service"))
    state.status = normalized_summary["status"]
    state.items_synced = normalized_summary.fetch("items_synced", state.items_synced || 0)
    state.detail = normalized_summary["detail"] if normalized_summary.key?("detail")
    state.last_attempted_at = parse_timestamp(normalized_summary["last_attempted"]) if normalized_summary["last_attempted"].present?
    state.last_successful_at = parse_timestamp(normalized_summary["last_successful"]) if normalized_summary["last_successful"].present?
    state.last_failed_at = parse_timestamp(normalized_summary["last_failed"]) if normalized_summary["last_failed"].present?
    state.save!
    state
  end

  # Advances the activity-sync cursor for a service. The activity cursor is
  # decoupled from the task-sync cursor (#224) so that an isolated activity
  # fetch failure cannot silently skip the observation window: callers
  # advance it only when every ActivityEmitter.emit_for call for the run
  # completed without raising.
  def self.record_activity_sync!(service_name:, at:)
    return if service_name.blank? || at.blank?

    state = find_or_initialize_by(service_name: service_name)
    state.last_successful_activity_sync_at = parse_timestamp(at)
    state.save!
    state
  end

  def to_log_hash
    {
      "service" => service_name,
      "status" => status,
      "items_synced" => items_synced,
      "last_attempted" => formatted_timestamp(last_attempted_at),
      "last_successful" => formatted_timestamp(last_successful_at),
      "last_successful_activity_sync" => formatted_timestamp(last_successful_activity_sync_at),
      "last_failed" => formatted_timestamp(last_failed_at),
      "detail" => detail
    }.compact
  end

  def self.parse_timestamp(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

    Time.zone.parse(value)
  end

  private_class_method :parse_timestamp

  private

  def formatted_timestamp(value)
    value&.utc&.strftime(TIMESTAMP_FORMAT)
  end
end
