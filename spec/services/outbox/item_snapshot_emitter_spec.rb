# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::ItemSnapshotEmitter do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:backfilled_at) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:item_class) do
    stub_const("ItemSnapshotSpecItem", Class.new(Base::SyncItem) do
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
  let(:item) do
    item_class.create!(
      title: "Buy milk",
      external_id: "of-42",
      url: "omnifocus:///task/of-42",
      source_service_name: "Omnifocus",
      options: { service_name: "Omnifocus", services: [], primary: "PrimaryService", tags: [] }
    )
  end

  before { item_class }

  describe ".emit_for_item" do
    it "enqueues an item snapshot row carrying the RDR-required fields" do
      travel_to(observed_at) { item.update_columns(last_observed_at: observed_at, first_observed_at: observed_at) }

      row = described_class.emit_for_item(
        item, observed_at:, detected_by: "backfill", backfilled_at:
      )

      expect(row).to be_persisted
      expect(row).to be_pending
      expect(row.record_kind).to eq("item")
      expect(row.event_type).to be_nil
      expect(row).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        external_id: "of-42",
        observed_at:
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-42:snapshot:2026-10-05T10:00:00.000000Z"
      )

      payload = row.payload
      expect(payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-42",
        "entity_type" => "task",
        "observed_at" => "2026-10-05T10:00:00.000000Z",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-42",
        "source_url" => "omnifocus:///task/of-42"
      )
    end

    it "marks the row as a backfill baseline rather than a change event" do
      row = described_class.emit_for_item(
        item, observed_at:, detected_by: "backfill", backfilled_at:
      )

      expect(row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-11T09:00:00.000000Z"
      )
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end

    it "does not duplicate the row when the same fact is emitted again" do
      emit = lambda do
        described_class.emit_for_item(
          item, observed_at:, detected_by: "backfill", backfilled_at:
        )
      end
      first_row = emit.call

      second_row = emit.call

      expect(second_row.id).to eq(first_row.id)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    end

    it "skips items that cannot be identified" do
      transient = item_class.new(external_id: "of-43")
      blank_id = item_class.create!(title: "No id", external_id: "", source_service_name: "Omnifocus")

      expect(described_class.emit_for_item(transient, observed_at:)).to be_nil
      expect(described_class.emit_for_item(blank_id, observed_at:)).to be_nil
      expect(OutboxEntry.count).to eq(0)
    end

    it "falls back to the item's own last observation time" do
      item.update_columns(last_observed_at: observed_at)

      row = described_class.emit_for_item(item, detected_by: "backfill")

      expect(row.observed_at).to eq(observed_at)
      expect(row.payload["observed_at"]).to eq("2026-10-05T10:00:00.000000Z")
    end
  end
end
