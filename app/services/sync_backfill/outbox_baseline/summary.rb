# frozen_string_literal: true

module SyncBackfill
  class OutboxBaseline
    # Accumulates the backfill counts (#222) and renders the operator-facing
    # summary: rows by service, mapping rows by confidence (withheld
    # low-confidence memberships included so they stay identifiable), and
    # skipped/incomplete records. The same report shape is returned for
    # real runs and dry runs so both can be compared directly.
    class Summary
      ITEM_OUTCOMES = %i[enqueued already_observed].freeze
      MAPPING_OUTCOMES = %i[enqueued existing withheld].freeze
      SERVICE_KEYS = %i[items mappings withheld].freeze

      def initialize
        @item_outcomes = ITEM_OUTCOMES.index_with { 0 }
        @mapping_outcomes = MAPPING_OUTCOMES.index_with { 0 }
        @item_skips = Hash.new(0)
        @mapping_skips = Hash.new(0)
        @services = Hash.new { |hash, service| hash[service] = SERVICE_KEYS.index_with { 0 } }
        @confidences = Hash.new(0)
      end

      def count_item(service_type, outcome)
        item_outcomes[outcome] += 1
        services[service_type][:items] += 1 if outcome == :enqueued
      end

      def skip_item(reason)
        item_skips[reason] += 1
      end

      # `confidence` is the local vocabulary (high/medium/low); the report
      # counts memberships by the contract's labels (confirmed/inferred/
      # tentative) so withheld rows line up with what TaskBridge Web would
      # have received.
      def count_mapping(service_type, confidence, outcome)
        mapping_outcomes[outcome] += 1
        confidences[contract_confidence(confidence)] += 1
        services[service_type][:withheld] += 1 if outcome == :withheld
        services[service_type][:mappings] += 1 unless outcome == :withheld
      end

      def skip_mapping(reason)
        mapping_skips[reason] += 1
      end

      def report(dry_run:)
        {
          dry_run:,
          items: item_outcomes.merge(skipped: stringified(item_skips)),
          mappings: mapping_outcomes.merge(skipped: stringified(mapping_skips)),
          by_service: services.sort.to_h,
          by_confidence: confidences.sort.to_h
        }
      end

      class << self
        def render(report)
          lines = [
            "Outbox baseline backfill#{' (DRY RUN — nothing was written)' if report[:dry_run]}",
            item_line(report[:items], report[:dry_run]),
            mapping_line(report[:mappings], report[:dry_run]),
            service_line(report[:by_service]),
            confidence_line(report[:by_confidence])
          ]
          lines.join("\n")
        end

        private

        def item_line(items, dry_run)
          "Items: #{items[:enqueued]} baseline snapshot rows #{verb(dry_run)}" \
            ", #{items[:already_observed]} already observed" \
            ", #{skip_note(items[:skipped], 'no skipped items')}"
        end

        def mapping_line(mappings, dry_run)
          "Mappings: #{mappings[:enqueued]} rows #{verb(dry_run)}" \
            ", #{mappings[:existing]} already enqueued" \
            ", #{mappings[:withheld]} withheld (low confidence; see counts by confidence)" \
            ", #{skip_note(mappings[:skipped], 'no skipped memberships')}"
        end

        def service_line(by_service)
          return "By service: none" if by_service.empty?

          detail = by_service.map do |service, counts|
            "#{service}: #{counts[:items]} items, #{counts[:mappings]} mappings, #{counts[:withheld]} withheld"
          end.join(" | ")
          "By service: #{detail}"
        end

        def confidence_line(by_confidence)
          return "By confidence: none" if by_confidence.empty?

          counts = by_confidence.map { |confidence, count| "#{confidence}=#{count}" }.join(", ")
          "By confidence: #{counts} (tentative rows are withheld, not published)"
        end

        def skip_note(skipped, empty_label)
          return empty_label if skipped.empty?

          skipped.map { |reason, count| "#{count} #{reason}" }.join(", ")
        end

        def verb(dry_run)
          dry_run ? "would be enqueued" : "enqueued"
        end
      end

      private

      attr_reader :item_outcomes, :mapping_outcomes, :item_skips, :mapping_skips, :services, :confidences

      # Skip reasons become report keys; strings keep the rendered summary
      # and any JSON export free of Ruby symbol noise.
      def stringified(skips)
        skips.each_with_object({}) { |(reason, count), hash| hash[reason.to_s] = count }
      end

      def contract_confidence(confidence)
        Outbox::MappingEmitter::CONFIDENCE.fetch(confidence, confidence)
      end
    end
  end
end
