# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncMappingProvenance, :full_options do
  let(:asana_item_class) do
    stub_const("ProvenanceSpecAsanaItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        {}
      end
    end)
  end
  let(:omnifocus_item_class) do
    stub_const("ProvenanceSpecOmnifocusItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end
  let(:reminders_item_class) do
    stub_const("ProvenanceSpecRemindersItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Reminders"
      end

      def external_data
        {}
      end
    end)
  end

  def build_item(item_class, service_name, title:, external_id:, notes: "")
    item_class.new(
      options: options.merge(service_name:),
      title:,
      external_id:,
      notes:
    )
  end

  describe ".preferred_for" do
    it "ranks every pair and picks a title match over unrelated first items" do
      alpha = build_item(asana_item_class, "Asana:work", title: "Alpha", external_id: "asana-1")
      beta = build_item(omnifocus_item_class, "Omnifocus", title: "Beta", external_id: "of-1")
      gamma = build_item(reminders_item_class, "Reminders", title: "Beta", external_id: "rem-1")

      provenance = described_class.preferred_for([alpha, beta, gamma])

      expect(provenance[:method]).to eq("title_fallback")
      expect(provenance[:confidence]).to eq("medium")
      expect(provenance[:metadata]).to include("matched_by" => "title", "title" => "Beta")
    end

    it "prefers a sync-id match in any pair over title matches" do
      alpha = build_item(asana_item_class, "Asana:work", title: "Alpha", external_id: "asana-1")
      beta = build_item(
        omnifocus_item_class, "Omnifocus",
        title: "Beta", external_id: "of-1", notes: "reminders_id: rem-1"
      )
      gamma = build_item(reminders_item_class, "Reminders", title: "Beta", external_id: "rem-1")

      provenance = described_class.preferred_for([alpha, beta, gamma])

      expect(provenance[:method]).to eq("source_sync_id")
      expect(provenance[:confidence]).to eq("high")
      expect(provenance[:metadata]).to include("matched_by" => "source_note", "note_key" => "reminders_id")
    end

    it "returns the first pair when every pair is equally weak" do
      alpha = build_item(asana_item_class, "Asana:work", title: "Alpha", external_id: "asana-1")
      beta = build_item(omnifocus_item_class, "Omnifocus", title: "Beta", external_id: "of-1")

      provenance = described_class.preferred_for([alpha, beta])

      expect(provenance).to eq(method: "manual_backfill", confidence: "low", metadata: {})
    end

    it "returns the first pair among equally strong matches" do
      alpha = build_item(asana_item_class, "Asana:work", title: "Alpha", external_id: "asana-1")
      beta = build_item(omnifocus_item_class, "Omnifocus", title: "Alpha", external_id: "of-1")
      gamma = build_item(reminders_item_class, "Reminders", title: "Gamma", external_id: "rem-1")
      delta = build_item(omnifocus_item_class, "Omnifocus", title: "Gamma", external_id: "of-2")

      provenance = described_class.preferred_for([alpha, beta, gamma, delta])

      expect(provenance[:method]).to eq("title_fallback")
      expect(provenance[:metadata]).to include("title" => "Alpha")
    end

    it "ignores nil items" do
      alpha = build_item(asana_item_class, "Asana:work", title: "Alpha", external_id: "asana-1")
      beta = build_item(omnifocus_item_class, "Omnifocus", title: "Alpha", external_id: "of-1")

      provenance = described_class.preferred_for([nil, alpha, nil, beta])

      expect(provenance[:method]).to eq("title_fallback")
    end

    it "raises when fewer than two items are given" do
      alpha = build_item(asana_item_class, "Asana:work", title: "Alpha", external_id: "asana-1")

      expect { described_class.preferred_for([alpha]) }.to raise_error(ArgumentError)
      expect { described_class.preferred_for([nil, alpha]) }.to raise_error(ArgumentError)
    end
  end

  describe ".method_priority" do
    it "ranks created_by_sync above every other known method" do
      priorities = SyncMappingProvenance::METHOD_PRIORITY.index_with { |method| described_class.method_priority(method) }

      expect(priorities["created_by_sync"]).to eq(priorities.values.max)
    end

    it "ranks unknown or typo'd methods below every known method instead of above them" do
      lowest_known_priority = SyncMappingProvenance::METHOD_PRIORITY.map { |method| described_class.method_priority(method) }.min

      expect(described_class.method_priority("soruce_sync_id")).to be < lowest_known_priority
    end
  end
end
