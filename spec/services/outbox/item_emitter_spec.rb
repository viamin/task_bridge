# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::ItemEmitter do
  let(:item_class) do
    stub_const("ItemEmitterSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "TestService"
      end

      def external_data
        {}
      end
    end)
  end
  let(:options) do
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item) do
    item_class.create!(
      options:,
      external_id: "item-1",
      title: "Buy milk",
      completed: false,
      due_at: Time.zone.parse("2026-10-06T17:00:00Z"),
      last_modified: Time.zone.parse("2026-10-04T18:58:02Z"),
      source_created_at: Time.zone.parse("2026-10-01T12:00:00Z")
    )
  end

  def emit_for(item_to_emit = item, observed_at: nil)
    described_class.emit_for_item(item_to_emit, observed_at:)
  end

  before do
    item_class
    item.update_columns(last_observed_at: observed_at, first_observed_at: observed_at)
  end

  it "enqueues an item snapshot row with the contract's required and optional fields" do
    entry = emit_for(item)

    expect(entry.record_kind).to eq("item")
    expect(entry.service_type).to eq("test_service")
    expect(entry.service_instance).to eq("test_service")
    expect(entry.external_id).to eq("item-1")
    expect(entry.observed_at).to eq(observed_at)
    expect(entry.idempotency_key).to eq("tb:v1:item:test_service:item-1:snapshot:2026-10-05T10:00:00.000000Z")
    expect(entry.payload).to include(
      "contract_version" => 1,
      "item_key" => "test_service:item-1",
      "entity_type" => "task",
      "observed_at" => "2026-10-05T10:00:00.000000Z",
      "title" => "Buy milk",
      "status" => "open",
      "is_deleted" => false,
      "due_at" => "2026-10-06T17:00:00.000000Z",
      "source_created_at" => "2026-10-01T12:00:00.000000Z",
      "tags" => ["TestService"],
      "source" => hash_including(
        "service_type" => "test_service",
        "service_instance" => "test_service",
        "external_id" => "item-1"
      )
    )
    expect(entry.payload).not_to include("notes_preview")
  end

  it "includes the sync collection mapping context when the item belongs to one" do
    collection = SyncCollection.create!(
      title: "Buy milk",
      mapping_method: "source_sync_id",
      mapping_confidence: "high"
    )
    item.update_column(:sync_collection_id, collection.id)

    entry = emit_for(item.reload)

    expect(entry.payload["sync_collection"]).to include(
      "sync_collection_id" => collection.id,
      "membership_role" => "member",
      "mapping_confidence" => "confirmed",
      "mapping_source" => "sync_id_note"
    )
  end

  it "resolves the parent shape when the item has a persisted parent" do
    parent = item_class.create!(options:, external_id: "item-0", title: "Groceries")
    item.update_column(:parent_item_id, parent.id)

    entry = emit_for(item.reload)

    expect(entry.payload["parent"]).to include("external_id" => "item-0", "item_key" => "test_service:item-0")
  end

  it "is idempotent per observed state: re-emitting reuses the row" do
    2.times { emit_for(item) }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "publishes a fresh row when the item is observed again" do
    emit_for(item)
    item.update_columns(last_observed_at: observed_at + 1.hour)

    emit_for(item.reload)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(2)
  end

  it "skips unpersisted items and items without an external id" do
    expect(emit_for(item_class.new(options:, external_id: "unpersisted"))).to be_nil

    item.update_column(:external_id, nil)
    expect(emit_for(item.reload)).to be_nil

    expect(OutboxEntry.where(record_kind: "item")).to be_empty
  end

  it "emits nothing in pretend mode" do
    item.options = options.merge(pretend: true)

    expect(emit_for(item)).to be_nil
    expect(OutboxEntry.where(record_kind: "item")).to be_empty
  end
end
