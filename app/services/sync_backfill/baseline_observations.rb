# frozen_string_literal: true

module SyncBackfill
  # Entry point for the #222 baseline backfill: combines the item snapshot
  # and mapping backfills into one summary shape so a single dry run (or
  # real run) reports both. See docs/backfill-baseline-observations.md for
  # how and when to run this before enabling TaskBridge Web publication.
  class BaselineObservations
    def self.summary
      { items: SyncBackfill::BaselineSnapshots.summary, mappings: SyncBackfill::BaselineMappings.summary }
    end

    def self.run!
      { items: SyncBackfill::BaselineSnapshots.run!, mappings: SyncBackfill::BaselineMappings.run! }
    end
  end
end
