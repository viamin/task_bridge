# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T10:00:00Z") }
  let(:options) { { service_name: "unused", services: [], primary: "Asana", tags: [], pretend: false } }
  let(:collection) do
    SyncCollection.create!(
      title: "Release the baseline",
      mapping_method: "source_sync_id",
      mapping_confidence: "high",
      mapping_metadata: { "matched_by" => "source_note" }
    )
  end

  before do
    Thread.current[:global_options] = options
    create_items
  end

  after { Thread.current[:global_options] = nil }

  it "backfills idempotent baseline snapshots and mappings for supported sources" do
    travel_to(observed_at) do
      first_summary = described_class.run!
      second_summary = described_class.run!

      expect(first_summary).to include("item_enqueued" => 4, "mapping_enqueued" => 4)
      expect(second_summary).to include("item_existing" => 4, "mapping_existing" => 4)
    end

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty

    %w[asana omnifocus github google_tasks].each do |service_type|
      item = OutboxEntry.find_by!(record_kind: "item", service_type:)
      expect(item.service_instance).to eq("#{service_type}:default")
      expect(item.payload.dig("provenance", "detected_by")).to eq("backfill")
      expect(item.payload.dig("provenance", "backfilled_at")).to eq(item.payload["observed_at"])
    end
  end

  it "withholds low-confidence memberships while reporting them" do
    collection.update!(mapping_method: "title_fallback", mapping_confidence: "low")

    summary = described_class.run!

    expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
    expect(summary).to include("mapping_skipped_low_confidence" => 4)
    expect(summary.fetch("mapping_confidences")).to include("low" => 4)
  end

  it "previews rows without changing provenance or the outbox" do
    item = collection.sync_items.first
    item.update_columns(source_service_name: nil, source_service_instance: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    expect(summary).to include("item_enqueued" => 4, "mapping_enqueued" => 4)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.source_service_name).to be_nil
    expect(item.last_observed_at).to be_nil
  end

  def create_items
    [Asana::Task, Omnifocus::Task, Github::Issue, GoogleTasks::Task].each_with_index do |item_class, index|
      item_class.create!(
        title: "Release the baseline #{index}",
        external_id: "external-#{index}",
        sync_collection: collection,
        options: options.merge(service_name: item_class.name.deconstantize)
      )
    end
  end
end
