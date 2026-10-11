# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:observed_at) { Time.zone.parse("2026-10-10T08:00:00Z") }

  let(:omnifocus_item_class) do
    stub_const("BaselineSpecOmnifocusItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      # The backfill must derive everything from local data; contacting a
      # provider (even to read) fails this spec.
      def external_data
        raise "external source contacted"
      end
    end)
  end
  let(:asana_item_class) do
    stub_const("BaselineSpecAsanaItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        raise "external source contacted"
      end
    end)
  end
  let(:github_item_class) do
    stub_const("BaselineSpecGithubItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Github"
      end

      def external_data
        raise "external source contacted"
      end
    end)
  end
  let(:google_tasks_item_class) do
    stub_const("BaselineSpecGoogleTasksItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "GoogleTasks"
      end

      def external_data
        raise "external source contacted"
      end
    end)
  end

  let(:confirmed_collection) { SyncCollection.create!(title: "Buy milk") }
  let(:inferred_collection) { SyncCollection.create!(title: "Write release notes") }
  let(:withheld_collection) { SyncCollection.create!(title: "Orphaned") }

  let!(:omnifocus_item) do
    omnifocus_item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-1",
      notes: "asana_work_id: asana-1",
      sync_collection: confirmed_collection
    )
  end
  let!(:asana_item) do
    asana_item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-1",
      notes: "omnifocus_id: of-1",
      sync_collection: confirmed_collection
    )
  end
  let!(:github_item) do
    github_item_class.create!(
      options: options.merge(service_name: "Github"),
      title: "Write release notes",
      external_id: "gh-1",
      notes: "",
      sync_collection: inferred_collection
    )
  end
  let!(:google_tasks_item) do
    google_tasks_item_class.create!(
      options: options.merge(service_name: "GoogleTasks"),
      title: "Write release notes",
      external_id: "gt-1",
      notes: "",
      sync_collection: inferred_collection
    )
  end
  let!(:withheld_item) do
    github_item_class.create!(
      options: options.merge(service_name: "Github"),
      title: "Orphaned",
      external_id: "gh-2",
      notes: "",
      sync_collection: withheld_collection
    )
  end
  let!(:incomplete_item) do
    omnifocus_item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "No external id",
      notes: ""
    )
  end

  before do
    travel_to(observed_at)
    omnifocus_item_class
    asana_item_class
    github_item_class
    google_tasks_item_class
  end

  after { travel_back }

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "#run!" do
    it "enqueues one baseline item snapshot per service with the default instance token" do
      travel_to(backfilled_at) { described_class.run! }

      aggregate_failures do
        expect(item_rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "github", "google_tasks")
        of_row = item_rows.find { |row| row.service_type == "omnifocus" }
        expect(of_row.service_instance).to eq("omnifocus:default")
        expect(of_row.external_id).to eq("of-1")
        expect(of_row.observed_at).to eq(omnifocus_item.reload.last_observed_at)
        expect(of_row.source_updated_at).to eq(omnifocus_item.last_modified)
        expect(of_row.idempotency_key).to eq(
          "tb:v1:item:omnifocus:default:of-1:snapshot:#{omnifocus_item.last_observed_at.utc.iso8601(6)}"
        )
        expect(item_rows.find { |row| row.service_type == "asana" }.service_instance).to eq("asana:work")
        expect(item_rows.find { |row| row.service_type == "github" }.service_instance).to eq("github:default")
        expect(item_rows.find { |row| row.service_type == "google_tasks" }.service_instance).to eq("google_tasks:default")
      end
    end

    it "marks item payloads as baseline current state, not change history" do
      travel_to(backfilled_at) { described_class.run! }

      of_row = item_rows.find { |row| row.service_type == "omnifocus" }
      expect(of_row.payload).to include(
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(of_row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1"
      )
      expect(of_row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => backfilled_at.utc.iso8601(6)
      )
      # Baseline only: no fabricated observations or sync-run summaries,
      # and no live diff baseline is stored on the items.
      expect(OutboxEntry.where.not(record_kind: %w[item mapping])).to be_empty
      expect(omnifocus_item.reload.last_snapshot).to be_nil
    end

    it "publishes confirmed and inferred mappings but withholds low confidence" do
      travel_to(backfilled_at) { described_class.run! }

      confirmed = mapping_rows.where(sync_collection_id: confirmed_collection.id)
      expect(confirmed.map(&:external_id)).to contain_exactly("of-1", "asana-1")
      expect(confirmed.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
      expect(confirmed.first.payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill",
        "backfilled_at" => backfilled_at.utc.iso8601(6)
      )

      inferred = mapping_rows.where(sync_collection_id: inferred_collection.id)
      expect(inferred.map(&:external_id)).to contain_exactly("gh-1", "gt-1")
      expect(inferred.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))

      expect(mapping_rows.where(sync_collection_id: withheld_collection.id)).to be_empty
    end

    it "summarizes counts by service, confidence, and skipped records" do
      summary = travel_to(backfilled_at) { described_class.run! }

      expect(summary[:dry_run]).to be false
      expect(summary[:items]).to include(
        considered: 6,
        enqueued: 5,
        already_backfilled: 0,
        by_service: { "omnifocus" => 1, "asana" => 1, "github" => 2, "google_tasks" => 1 },
        skipped_incomplete: { "omnifocus" => 1 }
      )
      expect(summary[:mappings]).to include(
        collections: 3,
        memberships: 5,
        enqueued: 4,
        by_confidence: { "confirmed" => 2, "inferred" => 2 },
        withheld_by_confidence: { "low" => 1 },
        skipped_incomplete: 0
      )
      expect(described_class.format_summary(summary)).to include(
        "Baseline backfill at #{backfilled_at.utc.iso8601(6)}",
        "asana: 1, github: 2, google_tasks: 1, omnifocus: 1",
        "confirmed: 2, inferred: 2",
        "1 withheld (low: 1)",
        "1 skipped incomplete (omnifocus: 1)"
      )
    end

    it "backfills missing provenance first so legacy rows gain baseline rows" do
      omnifocus_item.update_columns(source_service_name: nil, source_service_instance: nil,
                                    source_service_type: nil, source_external_id: nil,
                                    first_observed_at: nil, last_observed_at: nil)
      asana_item.update_columns(source_service_name: nil, source_service_instance: nil,
                                source_external_id: nil, first_observed_at: nil, last_observed_at: nil)

      travel_to(backfilled_at) { described_class.run! }

      expect(omnifocus_item.reload.source_service_name).to eq("Omnifocus")
      expect(omnifocus_item.last_observed_at).to be_present
      expect(asana_item.reload.source_service_name).to eq("Asana:work")
      expect(item_rows.find { |row| row.external_id == "asana-1" }.service_instance).to eq("asana:work")
    end

    it "is idempotent: reruns enqueue nothing new and never rewrite stored rows" do
      travel_to(backfilled_at) { described_class.run! }
      stored_item_row = item_rows.find { |row| row.service_type == "omnifocus" }
      stored_payload = stored_item_row.payload

      summary = travel_to(backfilled_at + 1.hour) { described_class.run! }

      expect(OutboxEntry.count).to eq(9)
      expect(stored_item_row.reload.payload).to eq(stored_payload)
      expect(summary[:items]).to include(enqueued: 0, already_backfilled: 5)
      expect(summary[:mappings]).to include(enqueued: 4, by_confidence: { "confirmed" => 2, "inferred" => 2 })
    end

    it "reports and skips rows whose outbox write keeps failing" do
      allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

      expect do
        travel_to(backfilled_at) { described_class.run! }
      end.to output(/dropping baseline item for omnifocus:default:of-1/).to_stderr

      expect(OutboxEntry.count).to eq(0)
    end
  end

  describe ".dry_run" do
    it "writes nothing and previews the counts a real run would produce" do
      omnifocus_item.update_columns(source_service_name: nil, source_service_instance: nil,
                                    source_external_id: nil, first_observed_at: nil, last_observed_at: nil)

      summary = travel_to(backfilled_at) { described_class.dry_run }

      expect(OutboxEntry.count).to eq(0)
      expect(omnifocus_item.reload.last_observed_at).to be_nil
      expect(confirmed_collection.reload.mapping_method).to be_nil
      expect(summary[:dry_run]).to be true
      expect(summary[:items]).to include(
        enqueued: 5,
        by_service: { "omnifocus" => 1, "asana" => 1, "github" => 2, "google_tasks" => 1 },
        skipped_incomplete: { "omnifocus" => 1 }
      )
      expect(summary[:mappings]).to include(
        by_confidence: { "confirmed" => 2, "inferred" => 2 },
        withheld_by_confidence: { "low" => 1 }
      )
      expect(described_class.format_summary(summary)).to include("(dry run)", "would enqueue")
    end

    it "counts identities that already have baseline rows as already backfilled" do
      travel_to(backfilled_at) { described_class.run! }

      summary = travel_to(backfilled_at + 1.hour) { described_class.dry_run }

      expect(summary[:items]).to include(enqueued: 0, already_backfilled: 5)
      expect(OutboxEntry.count).to eq(9)
    end
  end
end
