# frozen_string_literal: true

module Outbox
  # Diffs the previously published normalized snapshot against the newly
  # observed one and yields the single-field transitions the observation
  # contract publishes (RDR #215: one row per transition). Only fields that
  # carry meaningful task facts are compared: identity, provenance-only, and
  # mapping-owned fields are excluded so re-observation never emits noise,
  # and sync-note metadata never leaks into the diff because notes are
  # compared via their metadata-stripped digest.
  class SnapshotDiff
    OBSERVED_FIELDS = %w[
      title
      status
      completed_at
      due_at
      due_date
      start_at
      start_date
      flagged
      priority
      estimated_minutes
      project
      tags
      assignee
      notes_digest
      parent_item_id
      sub_item_count
      sub_item_keys
    ].freeze

    # Containment/classification facts adapters keep in `metadata` today.
    OBSERVED_METADATA_FIELDS = %w[folder list list_id section].freeze

    def self.transitions(previous_snapshot, new_snapshot)
      return [] if previous_snapshot.blank? || new_snapshot.blank?

      previous = previous_snapshot.deep_stringify_keys
      current = new_snapshot.deep_stringify_keys
      observed_field_names.filter_map do |field|
        from = normalize(field_value(previous, field))
        to = normalize(field_value(current, field))
        next if from == to

        { "field" => field, "from" => from, "to" => to }
      end
    end

    def self.observed_field_names
      OBSERVED_FIELDS + OBSERVED_METADATA_FIELDS.map { |field| "metadata.#{field}" }
    end

    class << self
      private

      def field_value(snapshot, field)
        return snapshot.dig("metadata", field.delete_prefix("metadata.")) if field.start_with?("metadata.")

        snapshot[field]
      end

      # Values must compare identically whether they were just read from a
      # provider (Time objects) or restored from the stored JSON baseline
      # (ISO 8601 strings), so timestamps normalize to microsecond UTC
      # strings on both sides. Arrays sort for order-insensitive stability.
      def normalize(value)
        return value.map { |element| normalize(element) }.sort if value.is_a?(Array)
        return value.utc.iso8601(6) if value.respond_to?(:utc)

        value
      end
    end
  end
end
