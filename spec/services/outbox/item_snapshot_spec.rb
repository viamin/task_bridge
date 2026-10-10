# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::ItemSnapshot do
  let(:item_class) do
    stub_const("ItemSnapshotSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "GoogleTasks"
      end

      def external_data
        {}
      end
    end)
  end
  let(:observed_at) { Time.zone.parse("2026-10-10T09:00:00Z") }
  let(:provenance) { { detected_by: "backfill", backfilled_at: "2026-10-10T09:05:00.000000Z" } }
  let(:item) do
    item_class.new(
      options: { services: [], primary: "Omnifocus", tags: [] },
      external_id: "gt-1",
      title: "Buy milk",
      completed: false,
      last_modified: Time.zone.parse("2026-10-09T18:00:00Z"),
      due_at: Time.zone.parse("2026-10-11T17:00:00Z")
    )
  end

  before { item_class }

  it "builds the minimum RDR item snapshot from persisted state" do
    payload = described_class.for(item, observed_at:, provenance:)

    expect(payload).to include(
      contract_version: 1,
      item_key: "google_tasks:gt-1",
      entity_type: "task",
      observed_at: "2026-10-10T09:00:00.000000Z",
      title: "Buy milk",
      status: "open",
      is_deleted: false,
      source_updated_at: "2026-10-09T18:00:00.000000Z",
      due_at: "2026-10-11T17:00:00.000000Z",
      source: {
        service_type: "google_tasks",
        service_instance: "google_tasks:default",
        external_id: "gt-1",
        source_url: nil
      },
      provenance: provenance
    )
  end

  it "normalizes completion state and timestamps" do
    item.completed = true
    item.completed_at = Time.zone.parse("2026-10-10T08:00:00Z")
    item.source_created_at = Time.zone.parse("2026-10-01T12:00:00Z")

    payload = described_class.for(item, observed_at:, provenance:)

    expect(payload).to include(status: "completed", completed_at: "2026-10-10T08:00:00.000000Z",
                               source_created_at: "2026-10-01T12:00:00.000000Z")
  end

  it "coalesces date-only columns into the datetime fields" do
    item.due_at = nil
    item.due_date = Time.zone.parse("2026-10-12T00:00:00Z")
    item.start_at = nil
    item.start_date = Time.zone.parse("2026-10-11T00:00:00Z")

    payload = described_class.for(item, observed_at:, provenance:)

    expect(payload).to include(due_at: "2026-10-12T00:00:00.000000Z", started_at: "2026-10-11T00:00:00.000000Z")
  end
end
