# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::ItemSnapshotEmitter do
  let(:item_class) do
    stub_const("BaselineSnapshotItem", Class.new(Base::SyncItem) do
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
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item) do
    item_class.create!(title: "Buy milk", external_id: "of-1", last_modified: observed_at,
                       options: { service_name: "Omnifocus", services: [], primary: "Asana", tags: [] })
  end

  before { item_class }

  it "writes one idempotent baseline snapshot and advances the local diff baseline" do
    2.times { described_class.emit_for(item, observed_at:) }

    row = OutboxEntry.find_by(record_kind: "item")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(row.service_instance).to eq("omnifocus:default")
    expect(row.payload).to include(
      "observed_at" => "2026-10-05T10:00:00.000000Z",
      "provenance" => hash_including("detected_by" => "backfill", "baseline" => true)
    )
    expect(item.reload.last_snapshot).to include("title" => "Buy milk")
  end
end
