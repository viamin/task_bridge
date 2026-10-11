# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  let(:output) { StringIO.new }
  let(:item_classes) do
    {
      "Omnifocus" => Omnifocus::Task,
      "Asana" => Asana::Task,
      "Github" => Github::Issue,
      "GoogleTasks" => GoogleTasks::Task
    }
  end

  def create_item(provider, collection:, suffix: "primary")
    item_classes.fetch(provider).create!(
      title: "Baseline #{provider}",
      external_id: "#{provider.downcase}-#{suffix}",
      sync_collection: collection,
      options: { service_name: provider, services: [], primary: "PrimaryService", tags: [] }
    )
  end

  it "seeds idempotent baseline item snapshots and publishes only non-tentative memberships" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    %w[Omnifocus Asana Github GoogleTasks].each { |provider| create_item(provider, collection: confirmed) }
    withheld = SyncCollection.create!(title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item("Omnifocus", collection: withheld, suffix: "review")

    described_class.run!(output:)
    first_rows = OutboxEntry.order(:id).pluck(:idempotency_key, :record_kind, :payload)
    described_class.run!(output:)

    expect(OutboxEntry.order(:id).pluck(:idempotency_key, :record_kind, :payload)).to eq(first_rows)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to match_array(
      %w[omnifocus-primary asana-primary github-primary googletasks-primary]
    )
    expect(OutboxEntry.find_by(external_id: "omnifocus-primary").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.where(record_kind: "item").first.payload.dig("provenance", "detected_by")).to eq("backfill")
  end

  it "reports a non-mutating dry run by service, confidence, and skipped mappings" do
    collection = SyncCollection.create!(title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item("GoogleTasks", collection:)

    described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.count).to eq(0)
    expect(output.string).to include(
      "no records were changed",
      "google_tasks=1",
      "low=1",
      "mappings_withheld_low_confidence=1"
    )
  end
end
