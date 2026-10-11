# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T10:00:00Z") }

  def create_item(item_class, service_name:, external_id:, collection:, **attributes)
    item_class.create!(
      {
        options: options.merge(service_name:),
        title: "Baseline task #{external_id}",
        external_id:,
        sync_collection: collection,
        last_modified: observed_at,
        notes: ""
      }.merge(attributes)
    )
  end

  it "seeds idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    omnifocus = create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-1", collection: nil)
    asana = create_item(Asana::Task, service_name: "Asana:work", external_id: "asana-1", collection: nil)
    github = create_item(Github::Issue, service_name: "Github", external_id: "gh-1", collection: nil, github_issue: {})
    google = create_item(GoogleTasks::Task, service_name: "GoogleTasks", external_id: "gt-1", collection: nil)

    travel_to(observed_at) do
      first_summary = described_class.run!
      second_summary = described_class.run!

      expect(first_summary).to include(item_snapshots: 4, mapping_memberships: 0)
      expect(second_summary).to include(item_snapshots: 4, mapping_memberships: 0)
    end

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.pluck(:external_id)).to eq(%w[asana-1 gh-1 gt-1 of-1])
    expect(rows.pluck(:event_type)).to all(be_nil)
    expect(rows.pluck(:idempotency_key).uniq.size).to eq(4)
    expect(rows.find_by!(external_id: "of-1").service_instance).to eq("omnifocus:default")
    expect(rows.find_by!(external_id: "asana-1").payload).to include(
      "provenance" => {
        "detected_by" => "backfill",
        "backfilled_at" => asana.reload.last_observed_at.iso8601(6)
      }
    )
    expect([omnifocus, asana, github, google]).to all(satisfy { |item| item.reload.last_snapshot.present? })
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
  end

  it "reports but withholds low-confidence mappings and emits confirmed and inferred mappings" do
    high = SyncCollection.create!(title: "High")
    medium = SyncCollection.create!(title: "Medium")
    low = SyncCollection.create!(title: "Low")
    create_item(Asana::Task, service_name: "Asana", external_id: "high-1", collection: high, notes: "omnifocus_id: of-1")
    create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-1", collection: high, notes: "asana_id: high-1")
    create_item(Asana::Task, service_name: "Asana", external_id: "medium-1", collection: medium, title: "Same title")
    create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "medium-2", collection: medium, title: "Same title")
    create_item(Asana::Task, service_name: "Asana", external_id: "low-1", collection: low, title: "Different")
    create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "low-2", collection: low, title: "Also different")

    summary = described_class.run!

    expect(summary[:by_confidence]).to include("high" => 2, "medium" => 2, "low" => 2)
    expect(summary[:skipped]).to include(skipped_mappings_low_confidence: 1)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("high-1", "of-1", "medium-1", "medium-2")
    expect(OutboxEntry.where(record_kind: "mapping").map { |row| row.payload["mapping_confidence"] })
      .to contain_exactly("confirmed", "confirmed", "inferred", "inferred")
  end

  it "does not mutate data during dry runs and reports incomplete items" do
    collection = SyncCollection.create!(title: "Incomplete")
    item = create_item(Asana::Task, service_name: "Asana", external_id: "", collection:)
    item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil,
                        source_external_id: nil, first_observed_at: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(dry_run: true, item_snapshots: 0)
    expect(summary[:skipped]).to include(skipped_items_missing_external_id: 1, skipped_mappings_low_confidence: 1)
    expect(item.reload.source_service_name).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end
end
