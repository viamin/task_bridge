# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T10:00:00Z") }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  # Representative records across the four services named in #222's
  # acceptance criteria, at three mapping confidence levels.
  let!(:sync_id_collection) do
    SyncCollection.create!(title: "Ship release").tap do |collection|
      Omnifocus::Task.create!(
        options:, title: "Ship release", external_id: "of-1",
        notes: "github_repo_1_id: gh-1", source_service_name: "Omnifocus",
        sync_collection: collection
      )
      Github::Issue.create!(
        options:, title: "Ship release", external_id: "gh-1",
        notes: "omnifocus_id: of-1", source_service_name: "Github:repo-1",
        sync_collection: collection
      )
    end
  end
  let!(:title_collection) do
    SyncCollection.create!(title: "Write docs").tap do |collection|
      Omnifocus::Task.create!(
        options:, title: "Write docs", external_id: "of-9", source_service_name: "Omnifocus",
        sync_collection: collection
      )
      GoogleTasks::Task.create!(
        options:, title: "Write docs", external_id: "gt-9", source_service_name: "GoogleTasks",
        sync_collection: collection
      )
    end
  end
  let!(:unlinked_collection) do
    SyncCollection.create!(title: "Unconfirmed pair").tap do |collection|
      Asana::Task.create!(
        options:, title: "Draft plan", external_id: "asana-7", source_service_name: "Asana:work",
        sync_collection: collection
      )
      Omnifocus::Task.create!(
        options:, title: "Something else entirely", external_id: "of-7", source_service_name: "Omnifocus",
        sync_collection: collection
      )
    end
  end
  let!(:incomplete_item) do
    GoogleTasks::Task.create!(options:, title: "No external id", source_service_name: "GoogleTasks")
  end

  before do
    # Legacy rows predate the #216-#218 provenance columns.
    Base::SyncItem.update_all(
      source_service_instance: nil, source_service_type: nil, source_external_id: nil,
      source_url: nil, source_updated_at: nil, first_observed_at: nil, last_observed_at: nil
    )
    SyncCollection.update_all(
      mapping_method: nil, mapping_confidence: nil, mapping_metadata: nil,
      mapping_established_at: nil, mapping_last_observed_at: nil
    )
    travel_to(backfilled_at)
  end

  after { travel_back }

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  def row_for(service_instance, external_id, kind: "item")
    OutboxEntry.find_by(record_kind: kind, service_instance:, external_id:)
  end

  describe "#run!" do
    let(:summary) { described_class.run! }

    it "enqueues a baseline item snapshot for every complete item, keyed by source identity" do
      expect { summary }.to change { item_rows.count }.by(6)

      expect(item_rows.map { |row| [row.service_instance, row.external_id] }).to contain_exactly(
        ["omnifocus:default", "of-1"], ["github:repo-1", "gh-1"],
        ["omnifocus:default", "of-9"], ["google_tasks:default", "gt-9"],
        ["asana:work", "asana-7"], ["omnifocus:default", "of-7"]
      )
      expect(summary.to_h[:items]).to include(
        considered: 7,
        enqueued: 6,
        by_service: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 3 },
        skipped: { "missing_external_id" => 1 }
      )
    end

    it "marks item rows as baseline current state rather than change events" do
      summary

      omnifocus_row = row_for("omnifocus:default", "of-1")

      expect(omnifocus_row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-1:snapshot:#{Omnifocus::Task.find_by(external_id: 'of-1').last_observed_at.utc.iso8601(6)}"
      )
      expect(omnifocus_row.observed_at).to eq(Omnifocus::Task.find_by(external_id: "of-1").last_observed_at)
      expect(omnifocus_row.payload).to include(
        "contract_version" => 1,
        "entity_type" => "task",
        "item_key" => "omnifocus:of-1",
        "title" => "Ship release",
        "status" => "open",
        "is_deleted" => false
      )
      expect(omnifocus_row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1"
      )
      expect(omnifocus_row.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => backfilled_at.utc.iso8601(6),
        "first_observed_at" => omnifocus_row.observed_at.utc.iso8601(6)
      )
      expect(omnifocus_row.payload["sync_collection"]).to include(
        "sync_collection_id" => sync_id_collection.id,
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "enqueues mapping rows for confirmed and inferred memberships only" do
      expect { summary }.to change { mapping_rows.count }.by(4)

      expect(mapping_rows.map { |row| [row.service_instance, row.external_id] }).to contain_exactly(
        ["omnifocus:default", "of-1"], ["github:repo-1", "gh-1"],
        ["omnifocus:default", "of-9"], ["google_tasks:default", "gt-9"]
      )

      github_mapping = row_for("github:repo-1", "gh-1", kind: "mapping")
      expect(github_mapping.payload).to include(
        "mapping_type" => "representation_membership",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(github_mapping.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => backfilled_at.utc.iso8601(6)
      )

      title_mapping = row_for("google_tasks:default", "gt-9", kind: "mapping")
      expect(title_mapping.payload.values_at("mapping_confidence", "mapping_source")).to eq(%w[inferred title_match])
    end

    it "withholds low-confidence memberships but keeps them identifiable in the summary" do
      summary

      expect(row_for("asana:work", "asana-7", kind: "mapping")).to be_nil
      expect(row_for("omnifocus:default", "of-7", kind: "mapping")).to be_nil
      expect(summary.to_h[:mappings]).to include(
        considered: 6,
        enqueued: 4,
        by_confidence: { "confirmed" => 2, "inferred" => 2 },
        by_method: { "source_sync_id" => 2, "title_fallback" => 2 },
        withheld: { "low" => 2 }
      )
    end

    it "reports the provenance upgrade and writes no sync-run rows" do
      summary

      expect(summary.to_h).to include(
        dry_run: false,
        provenance: { items_backfilled: 7, collections_backfilled: 3 },
        sync_runs: { enqueued: 0 }
      )
      expect(summary.render).to include("sync_run summaries: none")
      expect(Omnifocus::Task.find_by(external_id: "of-1").source_service_name).to eq("Omnifocus")
      expect(sync_id_collection.reload.mapping_method).to eq("source_sync_id")
    end

    it "is idempotent: reruns neither duplicate rows nor rewrite provenance" do
      described_class.run!
      first_run_rows = OutboxEntry.count
      observed_at_after_first_run = Omnifocus::Task.find_by(external_id: "of-1").last_observed_at

      rerun = described_class.run!

      expect(OutboxEntry.count).to eq(first_run_rows)
      expect(rerun.to_h[:items]).to include(
        considered: 7, enqueued: 0, skipped: { "already_backfilled" => 6, "missing_external_id" => 1 }
      )
      expect(rerun.to_h[:mappings]).to include(
        considered: 6, enqueued: 0,
        skipped: { "already_backfilled" => 4 }, withheld: { "low" => 2 }
      )
      expect(Omnifocus::Task.find_by(external_id: "of-1").last_observed_at).to eq(observed_at_after_first_run)
    end

    it "does not enqueue a fresh baseline for items that changed since the first run" do
      described_class.run!
      changed = GoogleTasks::Task.find_by(external_id: "gt-9")
      changed.update!(title: "Write the docs", last_observed_at: changed.last_observed_at + 1.hour)

      expect { described_class.run! }.not_to(change { item_rows.count })
    end
  end

  describe "#run! with dry_run: true" do
    let(:summary) { described_class.run!(dry_run: true) }

    it "writes nothing while previewing the exact rows a real run enqueues" do
      summary

      expect(OutboxEntry.count).to eq(0)
      expect(Omnifocus::Task.find_by(external_id: "of-1").last_observed_at).to be_nil
      expect(sync_id_collection.reload.mapping_method).to be_nil

      real_summary = described_class.run!
      expect(real_summary.to_h[:items]).to include(summary.to_h[:items])
      expect(real_summary.to_h[:mappings]).to include(summary.to_h[:mappings])
    end

    it "summarizes counts by service, confidence, method, and skipped records" do
      rendered = summary.render

      expect(rendered).to include("dry run — nothing was written")
      expect(rendered).to include("would enqueue 6")
      expect(rendered).to include("by service: asana 1, github 1, google_tasks 1, omnifocus 3")
      expect(rendered).to include("by confidence: confirmed 2, inferred 2")
      expect(rendered).to include("by method: source_sync_id 2, title_fallback 2")
      expect(rendered).to include("withheld low-confidence: low 2")
      expect(rendered).to include("skipped: missing_external_id 1")
    end

    it "previews the identity a real run persists for legacy multi-instance rows" do
      Asana::Task.find_by(external_id: "asana-7").update_columns(source_service_name: nil, source_service_instance: nil)
      Omnifocus::Task.find_by(external_id: "of-7").update_columns(notes: "asana_work_id: asana-7")

      summary = described_class.run!(dry_run: true)
      real_summary = described_class.run!

      # The dry run previewed the peer-note-derived identity a real run
      # then persisted: same per-service counts, no :default fallback.
      expect(real_summary.to_h[:items][:by_service]).to eq(summary.to_h[:items][:by_service])
      expect(Asana::Task.find_by(external_id: "asana-7").reload.source_service_name).to eq("Asana:work")
      expect(row_for("asana:work", "asana-7").payload["item_key"]).to eq("asana_work:asana-7")
    end
  end
end
