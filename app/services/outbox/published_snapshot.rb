# frozen_string_literal: true

module Outbox
  # Renders a Base::SyncItem's normalized snapshot in its published form:
  # identical to Base::SnapshotSerializer's output but with timestamps
  # rendered as ISO 8601 UTC so JSON round-trips keep microsecond
  # precision and stay diff-stable. Shared by the observation emitter
  # (#219) and the baseline backfill (#222) so both publish the same
  # snapshot shape.
  module PublishedSnapshot
    module_function

    def for(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
    end
  end
end
