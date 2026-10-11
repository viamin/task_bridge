# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::BaselineBackfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:backfilled_at) { now.utc.iso8601(6) }

  def create_item(klass, service_name:, **attributes)
    klass.create!(
      attributes.merge(options: { service_name:, services: [], primary: "Omnifocus", tags: [] })
    )
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "baseline item snapshots" do
    it "enqueues one baseline item per existing sync item across services" do
      omnifocus_item = create_item(Omnifocus::Task, service_name: "Omnifocus",
                                                    title: "Buy milk", external_id: "of-1", notes: "asana_work_id: asana-1")
      create_item(Asana::Task, service_name: "Asana:work",
                               title: "Buy milk", external_id: "asana-1",
                               url: "https://app.asana.com/0/1/asana-1")
      create_item(Github::Issue, service_name: "Github:repo-1",
                                 title: "Release checklist", external_id: "issue-42",
                                 status: "open", notes: "omnifocus_id: of-1")
      create_item(GoogleTasks::Task, service_name: "GoogleTasks",
                                     title: "Buy milk", external_id: "gt-1")

      travel_to(now) { described_class.run! }

      expect(item_rows.count).to eq(4)
      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty

      omnifocus_row = item_rows.find_by(external_id: "of-1")
      expect(omnifocus_row).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        payload_version: 1
      )
      expect(omnifocus_row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-1:snapshot:#{omnifocus_item.last_observed_at.utc.iso8601(6)}"
      )
      expect(omnifocus_row.payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => omnifocus_item.last_observed_at.utc.iso8601(6),
        "provenance" => { "detected_by" => "backfill", "backfilled_at" => backfilled_at }
      )
      expect(omnifocus_row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      )

      expect(item_rows.find_by(external_id: "asana-1").service_instance).to eq("asana:work")
      expect(item_rows.find_by(external_id: "asana-1").payload["source"]["source_url"])
        .to eq("https://app.asana.com/0/1/asana-1")
      expect(item_rows.find_by(external_id: "issue-42").service_instance).to eq("github:repo-1")
      expect(item_rows.find_by(external_id: "gt-1").service_instance).to eq("google_tasks:default")
    end

    it "normalizes a closed GitHub issue to completed status without raw issue data" do
      create_item(Github::Issue, service_name: "Github:repo-1",
                                 title: "Ship it", external_id: "issue-7", status: "closed")

      travel_to(now) { described_class.run! }

      payload = item_rows.find_by(external_id: "issue-7").payload
      expect(payload["status"]).to eq("completed")
      expect(payload["completed"]).to be(true)
      expect(payload["display_title"]).to eq("Ship it")
      expect(payload["metadata"]).to eq({})
    end

    it "never refreshes from or patches external systems" do
      create_item(Omnifocus::Task, service_name: "Omnifocus", title: "Buy milk", external_id: "of-1")

      allow_any_instance_of(Base::SyncItem).to receive(:refresh_from_external!) { raise "external read attempted" }
      allow_any_instance_of(Base::SyncItem).to receive(:patch_external_attributes) { raise "external write attempted" }

      expect { travel_to(now) { described_class.run! } }.not_to raise_error
      expect(item_rows.count).to eq(1)
    end
  end

  describe "idempotency" do
    it "re-enqueues nothing on a rerun, even after observation timestamps drift" do
      item = create_item(Omnifocus::Task, service_name: "Omnifocus", title: "Buy milk", external_id: "of-1")

      first_summary = travel_to(now) { described_class.run! }
      expect(first_summary.to_h.dig(:items, :enqueued)).to eq(1)

      second_summary = travel_to(now + 1.hour) { described_class.run! }
      expect(second_summary.to_h.dig(:items, :enqueued)).to eq(0)
      expect(second_summary.to_h.dig(:items, :already_backfilled)).to eq(1)
      expect(item_rows.count).to eq(1)

      # Live sync traffic bumps last_observed_at; a rerun must still not
      # mint a second baseline row for the same item.
      item.update_columns(last_observed_at: now + 2.hours)

      third_summary = travel_to(now + 3.hours) { described_class.run! }
      expect(third_summary.to_h.dig(:items, :already_backfilled)).to eq(1)
      expect(item_rows.count).to eq(1)
    end

    it "does not duplicate memberships the live pipeline already published" do
      collection = SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high")
      member = create_item(Asana::Task, service_name: "Asana:work", title: "Buy milk", external_id: "asana-1")
      peer = create_item(Omnifocus::Task, service_name: "Omnifocus", title: "Buy milk", external_id: "of-1")
      collection << member
      collection << peer

      travel_to(now) { described_class.run! }
      travel_to(now + 1.minute) { Outbox::MappingEmitter.emit_for_members(collection, members: [member], observed_at: now + 1.minute) }
      summary = travel_to(now + 2.minutes) { described_class.run! }

      expect(summary.to_h.dig(:mappings, :already_backfilled)).to eq(2)
      expect(mapping_rows.where(external_id: "asana-1").count).to eq(2)
      expect(mapping_rows.where(external_id: "of-1").count).to eq(1)
    end
  end

  describe "mapping rows" do
    let(:collection) { SyncCollection.create!(title: "Buy milk") }
    let(:member) { create_item(Asana::Task, service_name: "Asana:work", title: "Buy milk", external_id: "asana-1") }
    let(:peer) { create_item(Omnifocus::Task, service_name: "Omnifocus", title: "Buy milk", external_id: "of-1") }

    before do
      collection << member
      collection << peer
    end

    it "enqueues mapping rows for high-confidence memberships" do
      collection.update!(mapping_method: "source_sync_id", mapping_confidence: "high")
      expected_observed_at = collection.mapping_last_observed_at || collection.updated_at

      travel_to(now) { described_class.run! }

      expect(mapping_rows.count).to eq(2)
      row = mapping_rows.find_by(external_id: "asana-1")
      expect(row).to have_attributes(
        service_type: "asana",
        service_instance: "asana:work",
        sync_collection_id: collection.id,
        observed_at: expected_observed_at
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{collection.id}:membership:asana:work:asana-1:#{expected_observed_at.utc.iso8601(6)}"
      )
      expect(row.payload).to include(
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note",
        "membership_role" => "member"
      )
      expect(row.payload["sync_collection"]).to include("sync_collection_id" => collection.id, "title" => "Buy milk")
      expect(row.payload["member"]).to include(
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "external_id" => "asana-1"
      )
      expect(row.payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill",
        "backfilled_at" => backfilled_at
      )
    end

    it "translates medium confidence to inferred" do
      collection.update!(mapping_method: "title_fallback", mapping_confidence: "medium")

      travel_to(now) { described_class.run! }

      expect(mapping_rows.count).to eq(2)
      expect(mapping_rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      expect(mapping_rows.map { |row| row.payload["mapping_source"] }).to all(eq("title_match"))
    end

    it "withholds low-confidence memberships and keeps them identifiable in the summary" do
      collection.update!(mapping_method: "manual_backfill", mapping_confidence: "low")

      summary = travel_to(now) { described_class.run! }

      expect(mapping_rows).to be_empty
      expect(summary.to_h.dig(:mappings, :withheld)).to eq(2)
      expect(summary.to_h.dig(:mappings, :by_confidence, "low", :withheld)).to eq(2)
      expect(summary.render).to include("low confidence: 2 withheld")
    end

    it "withholds memberships without recorded confidence" do
      summary = travel_to(now) { described_class.run! }

      expect(mapping_rows).to be_empty
      expect(summary.to_h.dig(:mappings, :by_confidence, "unknown", :withheld)).to eq(2)
    end

    it "publishes the membership block on item snapshots for publishable mappings" do
      collection.update!(mapping_method: "source_sync_id", mapping_confidence: "high")

      travel_to(now) { described_class.run! }

      expect(item_rows.find_by(external_id: "asana-1").payload["sync_collection"]).to include(
        "sync_collection_id" => collection.id,
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
    end

    it "omits the membership block on item snapshots for withheld mappings" do
      collection.update!(mapping_method: "manual_backfill", mapping_confidence: "low")

      travel_to(now) { described_class.run! }

      expect(item_rows.count).to eq(2)
      expect(item_rows.find_by(external_id: "asana-1").payload).not_to include("sync_collection")
    end
  end

  describe "skipped and incomplete records" do
    it "counts records that cannot be identified or snapshotted" do
      create_item(Omnifocus::Task, service_name: "Omnifocus", title: "No id", external_id: nil)
      broken_class = stub_const("BackfillBrokenSpecItem", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        def provider
          "Broken"
        end

        def external_data
          {}
        end

        def normalized_metadata
          raise "snapshot failed"
        end
      end)
      broken_class.create!(title: "Broken", external_id: "broken-1",
                           options: { service_name: "Broken", services: [], primary: "Omnifocus", tags: [] })

      summary = travel_to(now) { described_class.run! }

      expect(item_rows).to be_empty
      expect(summary.to_h.dig(:items, :skipped)).to eq(2)
      expect(summary.to_h[:skip_reasons]).to eq(missing_external_id: 1, snapshot_error: 1)
      expect(summary.render).to include("skipped reasons: 1 missing_external_id, 1 snapshot_error")
    end
  end

  describe "dry run" do
    it "writes nothing and reports the counts it would enqueue" do
      create_item(Omnifocus::Task, service_name: "Omnifocus", title: "Buy milk", external_id: "of-1")
      collection = SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high")
      member = create_item(Asana::Task, service_name: "Asana:work", title: "Buy milk", external_id: "asana-1")
      collection << member
      create_item(Github::Issue, service_name: "Github:repo-1", title: "Release checklist",
                                 external_id: "issue-42", status: "open")

      summary = travel_to(now) { described_class.run!(dry_run: true) }

      expect(OutboxEntry.count).to eq(0)
      expect(summary.to_h).to include(dry_run: true)
      expect(summary.to_h.dig(:items, :enqueued)).to eq(3)
      expect(summary.to_h.dig(:items, :by_service)).to eq(
        "omnifocus" => { enqueued: 1, already_backfilled: 0, skipped: 0 },
        "asana" => { enqueued: 1, already_backfilled: 0, skipped: 0 },
        "github" => { enqueued: 1, already_backfilled: 0, skipped: 0 }
      )
      expect(summary.to_h.dig(:mappings, :enqueued)).to eq(1)
      expect(summary.render).to include("Baseline backfill dry run (nothing was enqueued)")
      expect(summary.render).to include("omnifocus: 1 to enqueue")
    end
  end
end
