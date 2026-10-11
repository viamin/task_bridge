# frozen_string_literal: true

module SyncBackfill
  # Accumulates the BaselineOutbox backfill report (#222): item snapshot
  # counts by service, mapping counts by confidence, withheld low-confidence
  # memberships (kept identifiable for manual cleanup because they are not
  # published), and skipped/incomplete records with reasons. Renders both a
  # structured hash and a human-readable summary for the rake tasks.
  class BaselineSummary
    def initialize(dry_run:)
      @dry_run = dry_run
      @items_enqueued = { total: 0, by_service: counter }
      @items_skipped = { total: 0, by_service: counter, by_reason: counter }
      @mappings_enqueued = { total: 0, by_confidence: counter }
      @mappings_withheld = { total: 0, by_confidence: counter, sync_collections: [] }
      @mappings_skipped = { total: 0, by_reason: counter }
    end

    def count_item(service_name)
      @items_enqueued[:total] += 1
      @items_enqueued[:by_service][service_name] += 1
    end

    def skip_item(service_name, reason)
      @items_skipped[:total] += 1
      @items_skipped[:by_service][service_name] += 1
      @items_skipped[:by_reason][reason] += 1
    end

    def count_mapping(confidence)
      @mappings_enqueued[:total] += 1
      @mappings_enqueued[:by_confidence][confidence] += 1
    end

    # Withheld mappings are never enqueued (#222 clarification: only
    # `confirmed` and `inferred` rows are published), so the summary is the
    # only place these memberships stay reviewable. Record which
    # collections (and how many members) they cover for later manual
    # cleanup.
    def withhold_mapping(collection, confidence, member_count)
      @mappings_withheld[:total] += member_count
      @mappings_withheld[:by_confidence][confidence] += member_count
      @mappings_withheld[:sync_collections] << {
        "sync_collection_id" => collection.id,
        "title" => collection.title,
        "members" => member_count
      }
    end

    def skip_mapping(reason)
      @mappings_skipped[:total] += 1
      @mappings_skipped[:by_reason][reason] += 1
    end

    def to_h
      {
        dry_run: @dry_run,
        items: {
          enqueued: totals(@items_enqueued, :by_service),
          skipped: {
            total: @items_skipped[:total],
            by_service: sorted(@items_skipped[:by_service]),
            by_reason: sorted(@items_skipped[:by_reason])
          }
        },
        mappings: {
          enqueued: totals(@mappings_enqueued, :by_confidence),
          withheld: totals(@mappings_withheld, :by_confidence)
                    .merge(sync_collections: @mappings_withheld[:sync_collections]),
          skipped: { total: @mappings_skipped[:total], by_reason: sorted(@mappings_skipped[:by_reason]) }
        }
      }
    end

    def to_s
      verb = @dry_run ? "would enqueue" : "enqueued"
      [
        "Baseline outbox backfill (#{@dry_run ? 'dry run' : 'write'}):",
        "  items: #{verb} #{@items_enqueued[:total]} #{breakdown(@items_enqueued[:by_service])}" \
        "#{skip_note(@items_skipped)}",
        "  mappings: #{verb} #{@mappings_enqueued[:total]} #{breakdown(@mappings_enqueued[:by_confidence])}",
        "  mappings withheld from publication: #{@mappings_withheld[:total]} " \
        "#{breakdown(@mappings_withheld[:by_confidence])}" \
        "#{" (#{collection_list})" if @mappings_withheld[:total].positive?}" \
        "#{skip_note(@mappings_skipped)}"
      ].join("\n")
    end

    private

    def counter
      Hash.new(0)
    end

    def totals(bucket, key)
      bucket.merge(key => sorted(bucket[key]))
    end

    def sorted(counts)
      counts.sort.to_h
    end

    def breakdown(counts)
      counts.empty? ? "" : "(#{counts.sort.map { |label, count| "#{label}: #{count}" }.join(', ')})"
    end

    def skip_note(skipped)
      return "" if skipped[:total].zero?

      ", skipped #{skipped[:total]} #{breakdown(skipped[:by_reason])}"
    end

    def collection_list
      @mappings_withheld[:sync_collections]
        .map { |entry| "##{entry['sync_collection_id']} #{entry['title']} (#{entry['members']} members)" }
        .join(", ")
    end
  end
end
