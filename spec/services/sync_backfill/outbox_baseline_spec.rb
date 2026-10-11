# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  let(:item_classes) do
    {
      "Omnifocus" => "BaselineOmnifocusItem",
      "Asana" => "BaselineAsanaItem",
      "Github" => "BaselineGithubItem",
      "Google Tasks" => "BaselineGoogleTasksItem"
    }.to_h do |provider, class_name|
      klass = Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        def self.attribute_map
          {}
        end

        def external_data
          {}
        end
      end
      stub_const(class_name, klass)
      [provider, klass]
    end
  end

  before do
    Thread.current[:global_options] = { pretend: false, services: [], primary: "Primary", tags: [] }
  end

  it "creates idempotent baseline snapshots and inferred mappings for representative services" do
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "title_fallback",
      mapping_confidence: "medium"
    )
    item_classes.each do |provider, item_class|
      item_class.create!(title: "Release checklist", external_id: "#{provider.parameterize}-1", sync_collection: collection)
    end

    first_summary = described_class.run!
    described_class.run!

    expect(first_summary[:items]).to eq(4)
    expect(first_summary[:mappings_medium]).to eq(4)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to contain_exactly(
      "omnifocus:default", "asana:default", "github:default", "google_tasks:default"
    )
    expect(OutboxEntry.where(record_kind: "item").first.payload).to include(
      "contract_version" => 1,
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => be_present)
    )
    expect(OutboxEntry.where(record_kind: "mapping").first.payload["mapping_confidence"]).to eq("inferred")
  end

  it "withholds low-confidence mappings while keeping them visible in the summary" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    item_classes.fetch("Asana").create!(title: "Uncertain", external_id: "asana-uncertain", sync_collection: collection)

    summary = described_class.run!

    expect(summary).to include(mappings_low: 1, mappings_withheld_low: 1)
    expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
  end

  it "reports a dry run without changing source provenance or the outbox" do
    item = item_classes.fetch("Github").create!(title: "Incomplete", external_id: "github-1")
    item.update_columns(last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    expect(summary[:items]).to eq(1)
    expect(item.reload.last_observed_at).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end
end
