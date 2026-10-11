# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:created_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "representative records across services" do
    # Github::Issue and GoogleKeep::Item compute `normalized_metadata` from a
    # transient per-fetch ivar (`github_issue`/`keep_item`) that is nil for a
    # row loaded cold from the database -- exactly backfill's case, and
    # exactly what calling `normalized_snapshot` here would hit. These items
    # are created directly via `create!`, the same way backfill finds them,
    # with no external fetch ever performed.
    let!(:asana_item) do
      Asana::Task.create!(title: "Buy milk", external_id: "asana-1", source_service_name: "Asana:work",
                          options: options.merge(service_name: "Asana:work"))
    end
    let!(:omnifocus_item) do
      Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1", source_service_name: "Omnifocus",
                              options: options.merge(service_name: "Omnifocus"))
    end
    let!(:github_item) do
      Github::Issue.create!(title: "Ship it", external_id: "gh-1", source_service_name: "Github",
                            options: options.merge(service_name: "Github"))
    end
    let!(:google_tasks_item) do
      GoogleTasks::Task.create!(title: "Buy milk", external_id: "gt-1", source_service_name: "GoogleTasks",
                                options: options.merge(service_name: "GoogleTasks"))
    end

    before { travel_to(created_at) { SyncBackfill::SourceProvenance.run! } }

    it "writes one baseline item snapshot per existing sync item without crashing on unsafe metadata" do
      summary = described_class.run!

      expect(item_rows.count).to eq(4)
      expect(summary[:items][:enqueued]).to eq(4)
      expect(summary[:items][:by_service]).to eq("asana" => 1, "omnifocus" => 1, "github" => 1, "google_tasks" => 1)

      github_row = item_rows.find_by(external_id: "gh-1")
      expect(github_row.service_type).to eq("github")
      expect(github_row.service_instance).to eq("github:default")
      expect(github_row.payload).to include(
        "title" => "Ship it",
        "status" => "open",
        "is_deleted" => false,
        "item_key" => github_item.item_key
      )
      expect(github_row.payload["provenance"]).to eq("detected_by" => "backfill")
      expect(github_row.payload).to have_key("backfilled_at")

      asana_row = item_rows.find_by(external_id: "asana-1")
      expect(asana_row.service_instance).to eq("asana:work")
    end

    it "is idempotent: rerunning does not create duplicate rows or change stored payloads" do
      described_class.run!
      first_run_rows = item_rows.order(:id).map { |row| [row.idempotency_key, row.payload] }

      described_class.run!

      expect(item_rows.count).to eq(4)
      expect(item_rows.order(:id).map { |row| [row.idempotency_key, row.payload] }).to eq(first_run_rows)
    end

    it "does not write anything in dry-run mode but still reports accurate counts" do
      summary = described_class.run!(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(summary[:items][:enqueued]).to eq(4)
    end

    it "never mutates the sync_items it reads" do
      expect { described_class.run! }.not_to(change { github_item.reload.attributes })
    end
  end

  describe "mapping membership confidence" do
    def member_for(klass, service_name, external_id, title: "Release checklist", notes: nil)
      klass.create!(title:, external_id:, notes:, source_service_name: service_name,
                    options: options.merge(service_name:))
    end

    it "publishes high-confidence sync-id mappings as confirmed" do
      collection = SyncCollection.create!(title: "Release checklist")
      source = member_for(Asana::Task, "Asana:work", "asana-1", notes: "omnifocus_id: of-1")
      target = member_for(Omnifocus::Task, "Omnifocus", "of-1", notes: "asana_work_id: asana-1")
      collection.update!(sync_items: [source, target])
      travel_to(created_at) { SyncBackfill::SourceProvenance.run! }

      described_class.run!

      rows = mapping_rows.where(sync_collection_id: collection.id)
      expect(rows.count).to eq(2)
      expect(rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
    end

    it "publishes title-matched mappings as inferred" do
      collection = SyncCollection.create!(title: "Release checklist")
      source = member_for(Asana::Task, "Asana:work", "asana-2")
      target = member_for(GoogleTasks::Task, "GoogleTasks", "gt-2")
      collection.update!(sync_items: [source, target])
      travel_to(created_at) { SyncBackfill::SourceProvenance.run! }

      described_class.run!

      rows = mapping_rows.where(sync_collection_id: collection.id)
      expect(rows.count).to eq(2)
      expect(rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
    end

    it "withholds low-confidence mappings from publication but surfaces them in the summary" do
      collection = SyncCollection.create!(title: "Unmapped item")
      member = member_for(GoogleTasks::Task, "GoogleTasks", "gt-3")
      collection.update!(sync_items: [member])
      travel_to(created_at) { SyncBackfill::SourceProvenance.run! }

      summary = described_class.run!

      expect(mapping_rows.where(sync_collection_id: collection.id)).to be_empty
      expect(summary[:mappings][:withheld_low_confidence]).to eq(1)
      expect(summary[:mappings][:confirmed]).to eq(0)
      expect(summary[:mappings][:inferred]).to eq(0)
    end

    it "counts collections without backfilled mapping provenance as skipped instead of withheld" do
      collection = SyncCollection.create!(title: "Not yet backfilled")
      member = member_for(GoogleTasks::Task, "GoogleTasks", "gt-4")
      collection.update!(sync_items: [member])
      # Deliberately skip SyncBackfill::SourceProvenance so mapping_confidence stays nil.

      summary = described_class.run!

      expect(mapping_rows).to be_empty
      expect(summary[:mappings][:skipped]).to eq(1)
      expect(summary[:mappings][:withheld_low_confidence]).to eq(0)
    end
  end
end
