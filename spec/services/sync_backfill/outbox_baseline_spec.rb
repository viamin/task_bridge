# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:base_options) { { services: [], primary: "Omnifocus", tags: [] } }

  before { travel_to(observed_at) }
  after { travel_back }

  def create_item(klass, external_id:, title: "Buy milk", collection: nil, **attributes)
    klass.create!(
      { title:, external_id:, sync_collection: collection,
        options: base_options.merge(attributes.delete(:options) || {}) }.merge(attributes)
    )
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "#run! with representative services" do
    let(:omnifocus_item) { create_item(Omnifocus::Task, external_id: "of-77") }
    let(:asana_item) do
      create_item(Asana::Task, external_id: "1201", options: { service_name: "Asana:work" })
    end
    let(:github_item) do
      create_item(Github::Issue, external_id: "issue-42", options: { service_name: "Github:repo-1" })
    end
    let(:google_tasks_item) { create_item(GoogleTasks::Task, external_id: "gt-9") }

    before do
      omnifocus_item
      asana_item
      github_item
      google_tasks_item
      described_class.run!
    end

    it "enqueues one baseline item snapshot per existing sync item, identified per service" do
      expect(item_rows.index_by(&:external_id)).to include(
        "of-77" => have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default"),
        "1201" => have_attributes(service_type: "asana", service_instance: "asana:work"),
        "issue-42" => have_attributes(service_type: "github", service_instance: "github:repo-1"),
        "gt-9" => have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")
      )
      expect(item_rows.map(&:observed_at).uniq).to eq([observed_at])
    end

    it "marks snapshots as baseline observations rather than change events" do
      payload = item_rows.find_by(external_id: "of-77").payload

      expect(payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-77",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => observed_at.utc.iso8601(6),
        "backfilled_at" => observed_at.utc.iso8601(6),
        "provenance" => { "detected_by" => "backfill" }
      )
      expect(payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-77"
      )
      # Clarified decision for #222: baseline backfill publishes item
      # snapshots only — never snapshot_seen observation rows.
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end

    it "derives stable idempotency keys from the deterministic observed_at" do
      expect(item_rows.find_by(external_id: "of-77").idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-77:snapshot:#{observed_at.utc.iso8601(6)}"
      )
    end
  end

  describe "idempotency" do
    it "does not duplicate rows or reset delivery state on rerun" do
      create_item(Omnifocus::Task, external_id: "of-1")
      first_summary = described_class.run!
      delivered = item_rows.find_by(external_id: "of-1")
      delivered.mark_delivered!

      second_summary = described_class.run!

      expect(item_rows.count).to eq(1)
      expect(item_rows.find_by(external_id: "of-1")).to be_delivered
      expect(first_summary[:items]).to include(created: 1, already_present: 0, planned: 1)
      expect(second_summary[:items]).to include(created: 0, already_present: 1, planned: 1)
      expect(second_summary[:mappings]).to include(memberships: 0)
    end

    it "keeps the canonical payload immutable when rerun after the item changed" do
      create_item(Omnifocus::Task, external_id: "of-1")
      described_class.run!
      original_payload = item_rows.find_by(external_id: "of-1").payload

      travel_to(observed_at + 2.hours) do
        Omnifocus::Task.find_by(external_id: "of-1").update!(title: "Buy oat milk")
        described_class.run!
      end

      unchanged = item_rows.find_by(idempotency_key: item_rows.find_by(external_id: "of-1").idempotency_key)
      expect(unchanged.payload).to eq(original_payload)
    end
  end

  describe "sync collection mappings" do
    let(:collection) { SyncCollection.create!(title: "Release checklist") }
    let(:member) { create_item(Omnifocus::Task, external_id: "of-1", collection:) }

    before { member }

    it "publishes high confidence memberships as confirmed mapping rows" do
      collection.update!(mapping_method: "source_sync_id", mapping_confidence: "high")

      summary = described_class.run!

      row = mapping_rows.find_by(external_id: "of-1")
      expect(row).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        sync_collection_id: collection.id,
        observed_at:
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{collection.id}:membership:omnifocus:default:of-1:#{observed_at.utc.iso8601(6)}"
      )
      expect(row.payload).to include(
        "mapping_type" => "representation_membership",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note",
        "backfilled_at" => observed_at.utc.iso8601(6)
      )
      expect(row.payload["member"]).to include("item_key" => "omnifocus:of-1", "external_id" => "of-1")
      expect(row.payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill",
        "backfilled_at" => observed_at.utc.iso8601(6)
      )
      expect(summary[:mappings]).to include(planned: 1, by_confidence: { "confirmed" => 1 })
    end

    it "publishes medium confidence memberships as inferred" do
      collection.update!(mapping_method: "title_fallback", mapping_confidence: "medium")

      summary = described_class.run!

      expect(mapping_rows.find_by(external_id: "of-1").payload)
        .to include("mapping_confidence" => "inferred", "mapping_source" => "title_match")
      expect(summary[:mappings][:by_confidence]).to eq("inferred" => 1)
    end

    it "withholds low confidence memberships but keeps them countable for review" do
      collection.update!(mapping_method: "manual_backfill", mapping_confidence: "low")

      summary = described_class.run!

      expect(mapping_rows).to be_empty
      expect(summary[:mappings]).to include(memberships: 1, planned: 0, withheld: 1, skipped: 0)
      expect(described_class.preview[:mappings]).to include(withheld: 1)
    end

    it "skips memberships whose provenance was never backfilled" do
      summary = described_class.run!

      expect(mapping_rows).to be_empty
      expect(summary[:mappings]).to include(memberships: 1, planned: 0, withheld: 0, skipped: 1)
    end

    it "omits the sync_collection block from item snapshots of withheld members" do
      collection.update!(mapping_method: "manual_backfill", mapping_confidence: "low")

      described_class.run!

      expect(item_rows.find_by(external_id: "of-1").payload).not_to have_key("sync_collection")
    end

    it "embeds the membership in the item snapshot for publishable collections" do
      collection.update!(mapping_method: "source_sync_id", mapping_confidence: "high")

      described_class.run!

      expect(item_rows.find_by(external_id: "of-1").payload["sync_collection"]).to eq(
        "sync_collection_id" => collection.id,
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
    end
  end

  describe "incomplete records" do
    it "skips items without an external id" do
      Omnifocus::Task.create!(title: "mystery task", options: base_options)

      summary = described_class.run!

      expect(item_rows).to be_empty
      expect(summary[:items]).to include(total: 1, planned: 0, skipped: 1)
    end

    it "skips memberships whose member lacks an external id" do
      collection = SyncCollection.create!(title: "Partial", mapping_method: "source_sync_id", mapping_confidence: "high")
      Omnifocus::Task.create!(title: "mystery task", sync_collection: collection, options: base_options)

      summary = described_class.run!

      expect(mapping_rows).to be_empty
      expect(summary[:mappings]).to include(memberships: 1, planned: 0, skipped: 1)
    end
  end

  describe "#preview" do
    it "reports the same plan as run! without writing any outbox row or touching local tables" do
      collection = SyncCollection.create!(title: "Release checklist", mapping_method: "source_sync_id",
                                          mapping_confidence: "high")
      member = create_item(Github::Issue, external_id: "issue-42", collection:,
                                          options: { service_name: "Github:repo-1" })
      state_before = [member.reload.updated_at, collection.reload.updated_at, member.last_observed_at]

      preview = described_class.preview

      expect(preview).to include(dry_run: true)
      expect(preview[:items]).to include(total: 1, planned: 1, created: 0, already_present: 0, by_service: { "github" => 1 })
      expect(preview[:mappings]).to include(
        memberships: 1, planned: 1, withheld: 0, by_confidence: { "confirmed" => 1 }, by_service: { "github" => 1 }
      )
      expect(OutboxEntry.count).to eq(0)
      expect(state_before).to eq([member.reload.updated_at, collection.reload.updated_at, member.last_observed_at])
    end
  end

  describe "local data safety" do
    it "never mutates existing sync items or collections" do
      collection = SyncCollection.create!(title: "Release checklist", mapping_method: "source_sync_id",
                                          mapping_confidence: "high")
      item = create_item(Asana::Task, external_id: "1201", collection:, options: { service_name: "Asana:work" })
      snapshot_before = { item: item.reload.attributes, collection: collection.reload.attributes }

      described_class.run!

      expect(item.reload.attributes).to eq(snapshot_before[:item])
      expect(collection.reload.attributes).to eq(snapshot_before[:collection])
    end
  end
end
