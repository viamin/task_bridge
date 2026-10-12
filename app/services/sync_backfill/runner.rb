# frozen_string_literal: true

module SyncBackfill
  # Orchestrates the baseline item snapshot and baseline mapping
  # backfills (#222, RDR #215 "Migration and Backfill Implications")
  # and prints a dry-run summary so operators can preview which rows
  # would be enqueued before publication to TaskBridge Web is enabled.
  #
  # Existing `sync_items` rows become baseline item snapshots; existing
  # `SyncCollection` memberships become mapping rows unless the
  # collection sits at `mapping_confidence: low`, in which case the
  # membership is withheld from the outbox and listed in the summary
  # for later manual cleanup. Skipped/incomplete records are also
  # surfaced by the summary.
  class Runner
    def self.run!(dry_run:, now: Time.current, logger: nil)
      new(dry_run:, now:, logger:).run!
    end

    def initialize(dry_run:, now:, logger:)
      @dry_run = dry_run
      @now = now
      @logger = logger
      @stream = $stdout
    end

    attr_reader :dry_run, :now, :logger

    def run!
      item_counts = backfill_items
      mapping_counts = backfill_mappings
      summary = combine(item_counts, mapping_counts)
      print_summary(summary)
      summary
    end

    private

    attr_reader :stream

    # Both the live and dry-run paths use the same baseline services
    # with a `dry_run:` flag, so the count shape is identical and the
    # summary can be trusted as a preview of a future live run.
    def backfill_items
      BaselineObservations.run!(dry_run:, now:, logger:)
    end

    def backfill_mappings
      MappingBaseline.run!(dry_run:, now:, logger:)
    end

    def combine(item_counts, mapping_counts)
      item_counts.merge(mapping_counts)
    end

    def print_summary(summary)
      stream.puts format_summary(summary)
    end

    def format_summary(summary)
      lines = []
      prefix = dry_run ? "Would backfill" : "Backfilled"
      lines << "#{prefix} #{summary[:items_emitted]} baseline item snapshots " \
               "(#{summary[:items_replayed]} already present, #{summary[:items_skipped]} skipped, #{summary[:items_seen]} seen)"
      lines << "  baseline item snapshots by service:"
      item_service_counts(summary).each do |service_type, count|
        lines << "    #{service_type}: #{count}"
      end
      lines << "#{prefix} #{summary[:mappings_emitted]} baseline mapping rows " \
               "(#{summary[:mappings_replayed]} already present) across #{summary[:collections_seen]} sync collections"
      lines << "  baseline mappings by confidence:"
      mapping_confidence_counts(summary).each do |confidence, count|
        lines << "    #{confidence}: #{count}"
      end
      lines << "Withheld #{summary[:memberships_withheld_low_confidence]} low-confidence memberships from publication; " \
               "#{summary[:memberships_skipped_incomplete]} memberships skipped as incomplete"
      lines << "Dry run only — no rows were written to the outbox." if dry_run
      lines.join("\n")
    end

    # The summary's per-service breakdown mirrors the row-level counters
    # so dry runs preview exactly which rows a live run would write.
    def item_service_counts(_summary)
      counts = Hash.new(0)
      Base::SyncItem.find_each do |item|
        next unless BaselineObservations.eligible?(item)

        counts[Base::Service.service_identifier_for(item.provider)] += 1
      end
      counts
    end

    def mapping_confidence_counts(_summary)
      counts = Hash.new(0)
      SyncCollection.find_each do |collection|
        members = collection.sync_items.to_a
        members.each do |member|
          next unless MappingBaseline.eligible?(member)

          if MappingBaseline.withhold?(collection)
            counts["low (withheld)"] += 1
          else
            counts[collection.mapping_confidence] += 1
          end
        end
      end
      counts
    end
  end
end
