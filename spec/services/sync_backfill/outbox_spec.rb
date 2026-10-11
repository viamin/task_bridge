# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox, :full_options do
  let(:item_classes) do
    %w[Omnifocus Asana Github GoogleTasks].map do |provider|
      stub_const("Backfill#{provider}Item", Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        def self.attribute_map
          {}
        end

        def external_data
          {}
        end
      end)
    end
  end

  def create_item(item_class, external_id:, collection:, notes: "")
    item_class.create!(
      title: "Release checklist", external_id:, notes:, sync_collection: collection,
      options: options.merge(service_name: item_class.new.provider)
    )
  end

  it "creates idempotent baseline snapshots and publishes only confident mappings" do
    omnifocus, asana, github, google_tasks = item_classes
    collection = SyncCollection.create!(title: "Release checklist")
    create_item(omnifocus, external_id: "of-1", collection:, notes: "asana_id: asana-1")
    create_item(asana, external_id: "asana-1", collection:, notes: "omnifocus_id: of-1")
    create_item(github, external_id: "gh-1", collection:)
    create_item(google_tasks, external_id: "gt-1", collection:)
    low_collection = SyncCollection.create!(title: "Unverified")
    create_item(github, external_id: "gh-low", collection: low_collection)

    first_summary = described_class.run!
    second_summary = described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(first_summary[:mapping_confidences]).to include("high" => 4, "low" => 1)
    expect(first_summary[:mappings_withheld_low_confidence]).to eq(1)
    expect(second_summary[:items_enqueued]).to eq(5)

    baseline = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
    expect(baseline.service_instance).to eq("omnifocus:default")
    expect(baseline.payload.dig("provenance", "detected_by")).to eq("backfill")
    expect(baseline.payload.dig("provenance", "baseline")).to be(true)
  end

  it "reports a dry run without writing provenance or outbox records" do
    github = item_classes.third
    item = create_item(github, external_id: "gh-1", collection: SyncCollection.create!(title: "Solo"))
    observed_at = item.last_observed_at

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(items_would_enqueue: 1, mappings_withheld_low_confidence: 1)
    expect(item.reload.last_observed_at).to eq(observed_at)
    expect(OutboxEntry.count).to eq(0)
  end
end
