# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Accumulates the backfill plan: item counts by service, mapping counts
    # by confidence, skipped/incomplete records, and the list of withheld
    # low-confidence memberships — the review surface for mappings that
    # never reach TaskBridge Web (clarified #222 decision).
    class Summary
      def initialize
        @items = { planned: 0, skipped_incomplete: 0 }
        @mappings = { planned: 0, withheld: 0, skipped_incomplete: 0 }
        @item_counts = Hash.new { |counts, service| counts[service] = { planned: 0, skipped_incomplete: 0 } }
        @confidence_counts = Hash.new(0)
        @withheld_memberships = []
      end

      def plan_item(service:)
        @items[:planned] += 1
        @item_counts[service][:planned] += 1
      end

      def skip_incomplete_item(service:)
        @items[:skipped_incomplete] += 1
        @item_counts[service][:skipped_incomplete] += 1
      end

      def plan_membership(confidence:)
        @mappings[:planned] += 1
        @confidence_counts[confidence] += 1
      end

      def skip_incomplete_membership
        @mappings[:skipped_incomplete] += 1
      end

      def withhold_membership(collection:, member:, confidence:)
        @mappings[:withheld] += 1
        @confidence_counts[confidence] += 1
        @withheld_memberships << {
          sync_collection_id: collection.id,
          title: collection.title,
          member_item_key: member.item_key,
          mapping_method: collection.mapping_method,
          mapping_confidence: confidence
        }
      end

      def to_h
        {
          items: @items.merge(by_service: @item_counts.deep_dup),
          mappings: @mappings.merge(
            by_confidence: @confidence_counts.sort.to_h,
            withheld_memberships: @withheld_memberships.map(&:dup)
          )
        }
      end

      def format
        [
          "Items: #{@items[:planned]} planned, #{@items[:skipped_incomplete]} skipped incomplete",
          "Items by service: #{service_line}",
          "Mappings: #{@mappings[:planned]} planned, #{@mappings[:withheld]} withheld low-confidence, " \
          "#{@mappings[:skipped_incomplete]} skipped incomplete",
          "Mappings by confidence: #{confidence_line}",
          *withheld_lines
        ].join("\n")
      end

      private

      def service_line
        @item_counts.keys.sort.map do |service|
          counts = @item_counts[service]
          skipped = ", #{counts[:skipped_incomplete]} skipped" if counts[:skipped_incomplete].positive?
          "#{service}: #{counts[:planned]} planned#{skipped}"
        end.join(", ")
      end

      def confidence_line
        counts = @confidence_counts.any? ? @confidence_counts.sort.map { |confidence, count| "#{confidence}: #{count}" } : ["none"]
        counts.join(", ")
      end

      def withheld_lines
        return ["Withheld low-confidence memberships: none"] if @withheld_memberships.empty?

        ["Withheld low-confidence memberships:", *@withheld_memberships.map do |membership|
          "  sync_collection #{membership[:sync_collection_id]} #{membership[:title].inspect}: " \
            "#{membership[:member_item_key]} (#{membership[:mapping_method] || 'unknown method'})"
        end]
      end
    end
  end
end
