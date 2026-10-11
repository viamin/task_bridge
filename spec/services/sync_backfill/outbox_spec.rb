# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::Outbox do
  let(:item_classes) do
    {
      "Omnifocus" => backfill_item_class("Omnifocus"),
      "Asana" => backfill_item_class("Asana"),
      "Github" => backfill_item_class("Github"),
      "GoogleTasks" => backfill_item_class("GoogleTasks")
    }
  end

  def backfill_item_class(provider)
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

  def create_item(provider:, external_id:, collection:)
    item_classes.fetch(provider).create!(
      title: "#{provider} baseline",
      external_id:,
      sync_collection: collection,
      options: options.merge(service_name: provider)
    )
  end

  def options
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end

  it "backfills idempotent baseline snapshots for supported existing services" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    withheld = SyncCollection.create!(title: "Withheld", mapping_method: "manual_backfill", mapping_confidence: "low")
    omnifocus = create_item(provider: "Omnifocus", external_id: "of-1", collection: confirmed)
    asana = create_item(provider: "Asana", external_id: "asana-1", collection: confirmed)
    github = create_item(provider: "Github", external_id: "github-1", collection: inferred)
    google_tasks = create_item(provider: "GoogleTasks", external_id: "google-1", collection: withheld)

    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("of-1", "asana-1", "github-1")
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-1").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "google-1").payload).to include(
      "provenance" => hash_including("detected_by" => "backfill", "baseline" => true)
    )
    expect([omnifocus, asana, github, google_tasks].map(&:reload)).to all(have_attributes(last_snapshot: be_present))

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
    expect(OutboxEntry.where(record_kind: "mapping").last.payload["mapping_confidence"]).to eq("inferred")
  end

  it "reports dry-run counts without writing rows" do
    collection = SyncCollection.create!(title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(provider: "Github", external_id: "github-2", collection:)
    create_item(provider: "Asana", external_id: nil, collection:)
    output = StringIO.new

    summary = described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.all).to be_empty
    expect(summary).to include("items.github" => 1, "skipped.items.missing_external_id.asana" => 1,
                               "skipped.mappings.low" => 2)
    expect(output.string).to include("TaskBridge outbox backfill dry run", "items.github: 1", "skipped.mappings.low: 2")
  end
end
