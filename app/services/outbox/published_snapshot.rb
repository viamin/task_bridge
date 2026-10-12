# frozen_string_literal: true

module Outbox
  # The published, JSON-stable form of a Base::SyncItem's normalized
  # snapshot: identical to Base::SyncItem#normalized_snapshot but with
  # timestamps rendered as ISO 8601 UTC so round-tripping through JSON
  # storage (and later comparison by Outbox::SnapshotDiff) stays precise
  # to the microsecond and diff-stable. Shared by live observation emission
  # (#219) and baseline backfill (#222) so both producers publish the same
  # shape for the same item.
  module PublishedSnapshot
    module_function

    def for(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
    end
  end
end
