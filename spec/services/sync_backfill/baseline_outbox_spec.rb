# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: ["TaskBridge"] } }
  let(:mapping_observed_at) { Time.zone.parse("2026-10-05T09:00:00Z") }

  let!(:confirmed_collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high",
                           mapping_established_at: mapping_observed_at, mapping_last_observed_at: mapping_observed_at)
  end
  let!(:inferred_collection) do
    SyncCollection.create!(title: "Fix login", mapping_method: "title_fallback", mapping_confidence: "medium",
                           mapping_established_at: mapping_observed_at, mapping_last_observed_at: mapping_observed_at)
  end
  let!(:low_confidence_collection) do
    SyncCollection.create!(title: "Maybe linked", mapping_method: "manual_backfill", mapping_confidence: "low",
                           mapping_established_at: mapping_observed_at, mapping_last_observed_at: mapping_observed_at)
  end

  # Representative records for each task service (#222 acceptance criteria)
  let!(:omnifocus_item) do
    Omnifocus::Task.create!(options: options.merge(service_name: "Omnifocus"), title: "Buy milk",
                            external_id: "of-1", url: "omnifocus:///task/of-1",
                            notes: "asana_work_id: asana-1", sync_collection: confirmed_collection)
  end
  let!(:asana_item) do
    Asana::Task.create!(options: options.merge(service_name: "Asana:work"), title: "Buy milk",
                        external_id: "asana-1", notes: "omnifocus_id: of-1", sync_collection: confirmed_collection)
  end
  let!(:github_item) do
    Github::Issue.create!(options: options.merge(service_name: "Github:repo-1"), github_issue: {},
                          title: "Fix login", external_id: "issue-42", status: "open",
                          url: "https://github.com/example/example/issues/42", sync_collection: inferred_collection)
  end
  let!(:google_tasks_item) do
    GoogleTasks::Task.create!(options: options.merge(service_name: "GoogleTasks"), title: "Fix login",
                              external_id: "gt-9", notes: "github_repo_1_id: issue-42",
                              sync_collection: inferred_collection)
  end
  let!(:low_confidence_omnifocus_item) do
    Omnifocus::Task.create!(options: options.merge(service_name: "Omnifocus"), title: "Maybe linked",
                            external_id: "of-2", sync_collection: low_confidence_collection)
  end
  let!(:low_confidence_asana_item) do
    Asana::Task.create!(options: options.merge(service_name: "Asana:work"), title: "Maybe linked",
                        external_id: "asana-2", sync_collection: low_confidence_collection)
  end
  let!(:incomplete_item) do
    GoogleTasks::Task.create!(options: options.merge(service_name: "GoogleTasks"), title: "Missing external id")
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "baseline item snapshots" do
    it "enqueues one row per publishable item with provider-specific identity" do
      described_class.run!

      expect(item_rows.map { |row| [row.service_type, row.service_instance, row.external_id] }).to contain_exactly(
        ["omnifocus", "omnifocus:default", "of-1"],
        ["omnifocus", "omnifocus:default", "of-2"],
        ["asana", "asana:work:default", "asana-1"],
        ["asana", "asana:work:default", "asana-2"],
        ["github", "github:repo-1:default", "issue-42"],
        ["google_tasks", "google_tasks:default", "gt-9"]
      )
    end

    it "marks rows as baseline backfill, not historical change events" do
      travel_to(Time.zone.parse("2026-10-06T12:00:00Z")) do
        described_class.run!
      end

      row = item_rows.find { |entry| entry.external_id == "issue-42" }
      expect(row.observed_at).to eq(github_item.reload.last_observed_at)
      expect(row.idempotency_key).to eq(
        "tb:v1:item:github:repo-1:default:issue-42:snapshot:#{row.observed_at.utc.iso8601(6)}"
      )
      expect(row.payload).to include(
        "contract_version" => 1,
        "item_key" => "github_repo_1:issue-42",
        "entity_type" => "task",
        "title" => "Fix login",
        "status" => "open",
        "is_deleted" => false
      )
      expect(row.payload["source"]).to include(
        "service_type" => "github",
        "service_instance" => "github:repo-1:default",
        "external_id" => "issue-42",
        "source_url" => "https://github.com/example/example/issues/42"
      )
      expect(row.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-06T12:00:00.000000Z"
      )
    end

    it "emits no observation or sync_run rows" do
      described_class.run!

      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "carries the membership block only for publishable mappings" do
      described_class.run!

      confirmed_payload = item_rows.find { |row| row.external_id == "of-1" }.payload
      expect(confirmed_payload["sync_collection"]).to include(
        "sync_collection_id" => confirmed_collection.id,
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      low_confidence_payload = item_rows.find { |row| row.external_id == "of-2" }.payload
      expect(low_confidence_payload).not_to have_key("sync_collection")
    end

    it "seeds the live diff baseline so a refresh only publishes real changes" do
      described_class.run!

      item = omnifocus_item.reload
      expect(item.last_snapshot).to include("item_key" => "omnifocus:of-1", "title" => "Buy milk")
      expect(Outbox::ObservationEmitter.emit_for_item(item, previous_snapshot: item.last_snapshot)).to eq([])
    end

    it "backfills provenance columns for legacy rows before snapshotting them" do
      omnifocus_item.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, source_updated_at: nil,
        first_observed_at: nil, last_observed_at: nil, source_metadata: nil
      )

      described_class.run!

      expect(omnifocus_item.reload.source_service_name).to eq("Omnifocus")
      expect(omnifocus_item.source_service_instance).to eq(nil)
      expect(omnifocus_item.source_external_id).to eq("of-1")
      expect(item_rows.map(&:external_id)).to include("of-1")
    end
  end

  describe "baseline mapping rows" do
    it "publishes confirmed and inferred memberships and withholds low confidence" do
      described_class.run!

      expect(mapping_rows.map(&:external_id)).to contain_exactly("of-1", "asana-1", "issue-42", "gt-9")
      expect(mapping_rows.map(&:sync_collection_id)).to contain_exactly(
        confirmed_collection.id, confirmed_collection.id, inferred_collection.id, inferred_collection.id
      )
    end

    it "translates internal confidence to the contract vocabulary" do
      described_class.run!

      expect(mapping_rows.find { |row| row.external_id == "of-1" }.payload["mapping_confidence"]).to eq("confirmed")
      expect(mapping_rows.find { |row| row.external_id == "gt-9" }.payload["mapping_confidence"]).to eq("inferred")
    end
  end

  describe "idempotency" do
    it "enqueues nothing new on a rerun" do
      described_class.run!
      first_run_counts = { items: item_rows.count, mappings: mapping_rows.count }

      second_summary = described_class.run!.to_h

      expect(item_rows.count).to eq(first_run_counts[:items])
      expect(mapping_rows.count).to eq(first_run_counts[:mappings])
      expect(second_summary[:items]).to include(total: 7, enqueued: 0, already_enqueued: 6, incomplete: 1)
      expect(second_summary[:mappings]).to include(members: 6, enqueued: 0, already_enqueued: 4, withheld: 2)
    end

    it "does not re-enqueue items whose observation advanced after a live sync" do
      described_class.run!

      omnifocus_item.update_columns(last_observed_at: Time.zone.parse("2026-10-07T08:00:00Z"),
                                    last_snapshot: { "title" => "Buy milk" })

      expect { described_class.run! }.not_to(change { OutboxEntry.count })
    end
  end

  describe "summary" do
    it "counts items by service and mappings by confidence, listing incomplete records" do
      summary = described_class.run!.to_h

      expect(summary[:dry_run]).to be(false)
      expect(summary[:items_by_service]).to eq(
        "asana" => { total: 2, enqueued: 2, already_enqueued: 0, incomplete: 0 },
        "github" => { total: 1, enqueued: 1, already_enqueued: 0, incomplete: 0 },
        "google_tasks" => { total: 2, enqueued: 1, already_enqueued: 0, incomplete: 1 },
        "omnifocus" => { total: 2, enqueued: 2, already_enqueued: 0, incomplete: 0 }
      )
      expect(summary[:mappings_by_confidence]).to eq(
        "confirmed" => { members: 2, enqueued: 2, already_enqueued: 0, incomplete: 0, withheld: 0 },
        "inferred" => { members: 2, enqueued: 2, already_enqueued: 0, incomplete: 0, withheld: 0 },
        "tentative" => { members: 2, enqueued: 0, already_enqueued: 0, incomplete: 0, withheld: 2 }
      )
      expect(summary[:incomplete_item_ids]).to eq([incomplete_item.id])
    end

    it "renders the counts for the rake task output" do
      output = StringIO.new

      described_class.run!.render(output)

      expect(output.string).to include("TaskBridge outbox backfill (applied)")
      expect(output.string).to include("google_tasks: 2 total, 1 enqueued, 0 already in outbox, 1 incomplete (skipped)")
      expect(output.string).to include("tentative: 2 memberships, 0 enqueued, 0 already in outbox, 2 withheld, 0 incomplete")
      expect(output.string).to include("first 10 ids: #{incomplete_item.id}")
    end
  end

  describe "dry run" do
    it "writes nothing and reports what would be enqueued" do
      summary = described_class.run!(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(summary.to_h).to include(dry_run: true)
      expect(summary.to_h[:items]).to include(total: 7, enqueued: 6, incomplete: 1)
      expect(summary.to_h[:mappings]).to include(members: 6, enqueued: 4, withheld: 2)
    end

    it "does not run the provenance backfill" do
      omnifocus_item.update_columns(source_service_name: nil, last_observed_at: nil)

      described_class.run!(dry_run: true)

      expect(omnifocus_item.reload.source_service_name).to be_nil
    end

    it "renders the dry-run summary" do
      output = StringIO.new

      described_class.run!(dry_run: true).render(output)

      expect(output.string).to include("dry run — nothing was written")
      expect(output.string).to include("omnifocus: 2 total, 2 would enqueue")
    end
  end
end
