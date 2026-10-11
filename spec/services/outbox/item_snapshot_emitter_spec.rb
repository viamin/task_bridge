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
    travel_to(observed_at) do
      item_class.create!(
        title: "Buy milk",
        external_id: "task-1",
        options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] }
      )
    end
  end

  before { item_class }

  describe ".emit_for_item" do
    it "enqueues one item row marked as a baseline backfill" do
      described_class.emit_for_item(item, backfilled_at:)

      row = OutboxEntry.find_by(record_kind: "item")
      expect(row).to have_attributes(
        external_id: "task-1",
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        observed_at:
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:task-1:snapshot:2026-10-05T10:00:00.000000Z"
      )
      expect(row.payload).to include(
        "item_key" => "omnifocus:task-1",
        "title" => "Buy milk",
        "entity_type" => "task"
      )
      expect(row.payload["source"]).to include("service_type" => "omnifocus", "service_instance" => "omnifocus:default")
      expect(row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-11T09:00:00.000000Z"
      )
    end

    it "does not advance or depend on the live observation diff baseline" do
      described_class.emit_for_item(item, backfilled_at:)

      expect(item.reload.last_snapshot).to be_nil
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end

    it "is idempotent across repeated runs" do
      described_class.emit_for_item(item, backfilled_at:)

      expect do
        described_class.emit_for_item(item, backfilled_at: backfilled_at + 1.day)
      end.not_to(change { OutboxEntry.where(record_kind: "item").count })
    end

    it "skips items without an external id" do
      item.external_id = nil

      expect(described_class.emit_for_item(item, backfilled_at:)).to be_nil
      expect(OutboxEntry.where(record_kind: "item")).to be_empty
    end

    it "isolates a failing write instead of raising" do
      allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

      expect do
        described_class.emit_for_item(item, backfilled_at:)
      end.to output(/dropping item snapshot for omnifocus:task-1/).to_stderr
      expect(OutboxEntry.where(record_kind: "item")).to be_empty
    end
  end
end
