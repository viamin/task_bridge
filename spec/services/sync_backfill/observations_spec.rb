# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Observations do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Asana", tags: [] } }
  let(:item_classes) do
    {
      "Omnifocus" => stub_item_class("BackfillOmnifocusItem", "Omnifocus"),
      "Asana" => stub_item_class("BackfillAsanaItem", "Asana"),
      "Github" => stub_item_class("BackfillGithubItem", "Github"),
      "GoogleTasks" => stub_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  def stub_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(provider, external_id:, collection: nil, notes: nil)
    item_classes.fetch(provider).create!(title: "Release", external_id:, notes:, sync_collection: collection,
                                         options: options.merge(service_name: provider))
  end

  it "backfills idempotent baseline snapshots for representative services without observations" do
    travel_to(observed_at) do
      create_item("Omnifocus", external_id: "of-1")
      create_item("Asana", external_id: "as-1")
      create_item("Github", external_id: "gh-1")
      create_item("GoogleTasks", external_id: "gt-1")

      described_class.run!
      described_class.run!
    end

    rows = OutboxEntry.where(record_kind: "item").order(:service_type)
    expect(rows.map(&:service_type)).to eq(%w[asana github google_tasks omnifocus])
    expect(rows.map(&:service_instance)).to eq(%w[asana:default github:default google_tasks:default omnifocus:default])
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(rows).to all(satisfy { |row| row.payload["event_type"].nil? })
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
  end

  it "publishes confirmed memberships, withholds low confidence mappings, and summarizes a dry run" do
    high_collection = SyncCollection.create!(title: "Release")
    low_collection = SyncCollection.create!(title: "Loose")
    create_item("Asana", external_id: "as-1", collection: high_collection, notes: "omnifocus_id: of-1")
    create_item("Omnifocus", external_id: "of-1", collection: high_collection, notes: "asana_id: as-1")
    create_item("Github", external_id: "gh-1", collection: low_collection)
    output = StringIO.new

    preview = described_class.run!(dry_run: true, output:)
    described_class.run!

    expect(preview.confidence).to include("high" => 1, "low" => 1)
    expect(output.string).to include("mapping confidence", "low_confidence_mapping")
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("as-1", "of-1")
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload)).to all(include("mapping_confidence" => "confirmed"))
  end
end
