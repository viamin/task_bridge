# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:created_at) { Time.zone.parse("2026-09-01T09:00:00Z") }
  let(:backfilled_at) { Time.zone.parse("2026-10-10T12:00:00Z") }
  let(:base_options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  # Representative records for OmniFocus, Asana, GitHub, and Google Tasks.
  # The OmniFocus and Asana rows are cleared back to legacy state (no
  # provenance) so every run also exercises the identity backfill; the
  # three collections cover sync-id, title-derived, and unevidenced
  # mappings.
  let!(:data) do
    travel_to(created_at) do
      linked = SyncCollection.create!(title: "Buy milk")
      titled = SyncCollection.create!(title: "Write docs")
      unmatched = SyncCollection.create!(title: "Unmatched pair")
      omnifocus = Omnifocus::Task.create!(
        title: "Buy milk", external_id: "of-77", url: "omnifocus:///task/of-77",
        notes: "asana_id: asana-123", last_modified: created_at - 1.day,
        sync_collection: linked
      )
      asana = Asana::Task.create!(
        title: "Buy milk", external_id: "asana-123",
        notes: "omnifocus_id: of-77", sync_collection: linked
      )
      asana_docs = Asana::Task.create!(title: "Write docs", external_id: "asana-200", sync_collection: titled)
      google_docs = GoogleTasks::Task.create!(title: "Write docs", external_id: "gt-9", sync_collection: titled)
      github = Github::Issue.create!(
        title: "Release checklist", external_id: "issue-42", status: "open",
        options: base_options.merge(service_name: "Github:repo-1"),
        sync_collection: unmatched
      )
      google_low = GoogleTasks::Task.create!(title: "Plan offsite", external_id: "gt-10", sync_collection: unmatched)
      incomplete = GoogleTasks::Task.create!(title: "No external id yet")
      [omnifocus, asana].each do |item|
        item.update_columns(
          source_service_name: nil,
          source_service_instance: nil,
          source_service_type: nil,
          source_external_id: nil,
          source_url: nil,
          source_created_at: nil,
          source_updated_at: nil,
          first_observed_at: nil,
          last_observed_at: nil,
          source_metadata: nil
        )
      end
      linked.update_columns(
        mapping_method: nil,
        mapping_confidence: nil,
        mapping_metadata: nil,
        mapping_established_at: nil,
        mapping_last_observed_at: nil
      )
      {
        linked_collection: linked, title_collection: titled, low_collection: unmatched,
        omnifocus_item: omnifocus, asana_item: asana, asana_docs_item: asana_docs,
        google_docs_item: google_docs, github_item: github, google_low_item: google_low,
        incomplete_item: incomplete
      }
    end
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "#run!" do
    let!(:summary) { travel_to(backfilled_at) { described_class.run! } }

    it "enqueues one baseline item snapshot per complete sync item for each representative service" do
      expect(item_rows.map(&:external_id)).to contain_exactly("of-77", "asana-123", "asana-200", "gt-9", "issue-42", "gt-10")
      expect(item_rows.map(&:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:default", "asana:default", "google_tasks:default", "github:repo-1", "google_tasks:default"
      )
    end

    it "marks item payloads as baseline backfill rather than history" do
      row = item_rows.find_by(external_id: "of-77")
      expect(row.event_type).to be_nil
      expect(row.observed_at).to eq(created_at)
      expect(row.idempotency_key).to eq("tb:v1:item:omnifocus:default:of-77:snapshot:2026-09-01T09:00:00.000000Z")
      expect(row.payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-77",
        "title" => "Buy milk",
        "observed_at" => "2026-09-01T09:00:00.000000Z",
        "is_deleted" => false
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-77",
        "source_url" => "omnifocus:///task/of-77"
      )
      expect(row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-10T12:00:00.000000Z"
      )
    end

    it "backfills identity provenance from parsed notes for legacy rows" do
      expect(data[:omnifocus_item].reload).to have_attributes(
        source_service_name: "Omnifocus",
        source_service_instance: nil,
        source_external_id: "of-77",
        source_url: "omnifocus:///task/of-77",
        last_observed_at: created_at
      )
      expect(data[:asana_item].reload.source_service_name).to eq("Asana")
    end

    it "enqueues mapping rows for high and medium confidence memberships and withholds low confidence" do
      confirmed = mapping_rows.where(sync_collection_id: data[:linked_collection].id)
      inferred = mapping_rows.where(sync_collection_id: data[:title_collection].id)
      expect(confirmed.map(&:external_id)).to contain_exactly("of-77", "asana-123")
      expect(mapping_confidences(confirmed)).to all(eq("confirmed"))
      expect(inferred.map(&:external_id)).to contain_exactly("asana-200", "gt-9")
      expect(mapping_confidences(inferred)).to all(eq("inferred"))
      expect(mapping_rows.where(sync_collection_id: data[:low_collection].id)).to be_empty
      expect(mapping_rows.map(&:idempotency_key)).to include(
        "tb:v1:map:sync_collection:#{data[:linked_collection].id}:membership:omnifocus:default:of-77:2026-09-01T09:00:00.000000Z"
      )
    end

    it "marks mapping payloads as baseline backfill" do
      published = mapping_rows.find_by(external_id: "gt-9")
      expect(published.payload["provenance"]).to include(
        "method" => "title_fallback",
        "confidence" => "medium",
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-10T12:00:00.000000Z"
      )
    end

    it "never writes observation or sync_run rows" do
      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
    end

    it "summarizes counts by service, confidence, and skipped records" do
      expect(summary[:items]).to include(total: 7, enqueued: 6, skipped: 1)
      expect(summary[:items][:by_service]).to eq(
        "omnifocus" => { enqueued: 1, skipped: 0, withheld: 0 },
        "asana" => { enqueued: 2, skipped: 0, withheld: 0 },
        "github" => { enqueued: 1, skipped: 0, withheld: 0 },
        "google_tasks" => { enqueued: 2, skipped: 1, withheld: 0 }
      )
      expect(summary[:mappings]).to include(total: 6, enqueued: 4, withheld: 2, skipped: 0)
      expect(summary[:mappings][:by_confidence]).to eq("high" => 2, "medium" => 2, "low" => 2)
      expect(summary[:mappings][:by_service]).to eq(
        "omnifocus" => { enqueued: 1, skipped: 0, withheld: 0 },
        "asana" => { enqueued: 2, skipped: 0, withheld: 0 },
        "github" => { enqueued: 0, skipped: 0, withheld: 1 },
        "google_tasks" => { enqueued: 1, skipped: 0, withheld: 1 }
      )
      expect(summary[:mappings][:withheld_memberships]).to be_empty
    end

    describe "running it again" do
      it "is idempotent: no new rows, no provenance churn" do
        expect do
          travel_to(backfilled_at + 1.day) { described_class.run! }
        end.not_to(change { OutboxEntry.count })

        expect(item_rows.count).to eq(6)
        expect(mapping_rows.count).to eq(4)
        expect(data[:omnifocus_item].reload.last_observed_at).to eq(created_at)
        expect(data[:linked_collection].reload.mapping_last_observed_at).to eq(created_at)
      end
    end

    private

    def mapping_confidences(rows)
      rows.map { |row| row.payload["mapping_confidence"] }
    end
  end

  describe "#run! with dry_run" do
    let!(:summary) { travel_to(backfilled_at) { described_class.run!(dry_run: true) } }

    it "writes nothing" do
      expect(OutboxEntry.count).to eq(0)
      expect(data[:omnifocus_item].reload.last_observed_at).to be_nil
      expect(data[:linked_collection].reload.mapping_method).to be_nil
    end

    it "summarizes what would be enqueued, by service and confidence" do
      expect(summary[:dry_run]).to be(true)
      expect(summary[:items]).to include(total: 7, enqueued: 6, skipped: 1)
      expect(summary[:items][:by_service]["github"]).to eq(enqueued: 1, skipped: 0, withheld: 0)
      expect(summary[:mappings]).to include(total: 6, enqueued: 4, withheld: 2)
      expect(summary[:mappings][:by_confidence]).to eq("high" => 2, "medium" => 2, "low" => 2)
    end

    it "lists the withheld low-confidence memberships for review" do
      expect(summary[:mappings][:withheld_memberships]).to contain_exactly(
        hash_including(
          sync_collection_id: data[:low_collection].id,
          title: "Unmatched pair",
          item_key: "github_repo_1:issue-42",
          mapping_method: "manual_backfill",
          confidence: "low"
        ),
        hash_including(item_key: "google_tasks:gt-10")
      )
    end
  end
end
