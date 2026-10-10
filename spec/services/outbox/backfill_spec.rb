# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-09T09:00:00Z") }
  let(:mapping_observed_at) { Time.zone.parse("2026-10-09T08:30:00Z") }

  let(:omnifocus_class) do
    stub_const("BackfillOmnifocusTask", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        raise "the backfill must not read external data"
      end
    end)
  end
  let(:asana_class) do
    stub_const("BackfillAsanaTask", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        raise "the backfill must not read external data"
      end
    end)
  end
  let(:github_class) do
    stub_const("BackfillGithubIssue", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Github"
      end

      def external_data
        raise "the backfill must not read external data"
      end
    end)
  end
  let(:google_tasks_class) do
    stub_const("BackfillGoogleTasksTask", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "GoogleTasks"
      end

      def external_data
        raise "the backfill must not read external data"
      end
    end)
  end
  let(:item_options) { { services: [], primary: "Omnifocus", tags: [] } }

  let(:omnifocus_task) do
    omnifocus_class.create!(
      title: "Ship the thing",
      external_id: "of-1",
      notes: "asana_work_id: asana-1",
      options: item_options.merge(service_name: "Omnifocus")
    )
  end
  let(:asana_task) do
    asana_class.create!(
      title: "Ship the thing",
      external_id: "asana-1",
      notes: "omnifocus_id: of-1",
      options: item_options.merge(service_name: "Asana:work")
    )
  end
  let(:github_issue) do
    github_class.create!(
      title: "Release checklist",
      external_id: "issue-9",
      url: "https://github.com/viamin/task_bridge/issues/9",
      notes: "",
      options: item_options.merge(service_name: "Github:repo-1")
    )
  end
  let(:google_task) do
    google_tasks_class.create!(
      title: "Release checklist",
      external_id: "gt-7",
      notes: "",
      options: item_options.merge(service_name: "GoogleTasks")
    )
  end
  let(:unclear_asana_task) do
    asana_class.create!(
      title: "Mystery one",
      external_id: "asana-99",
      notes: "",
      options: item_options.merge(service_name: "Asana:work")
    )
  end
  let(:unclear_omnifocus_task) do
    omnifocus_class.create!(
      title: "Mystery two",
      external_id: "of-99",
      notes: "",
      options: item_options.merge(service_name: "Omnifocus")
    )
  end
  let(:incomplete_item) do
    omnifocus_class.create!(
      title: "No external id",
      notes: "",
      options: item_options.merge(service_name: "Omnifocus")
    )
  end

  let(:linked_collection) do
    SyncCollection.create!(title: "Ship the thing").tap do |collection|
      asana_task.update!(sync_collection: collection)
      omnifocus_task.update!(sync_collection: collection)
      collection.update_mapping_provenance!(
        method: "source_sync_id", confidence: "high",
        metadata: { "matched_by" => "source_note" }, observed_at: mapping_observed_at
      )
    end
  end
  let(:titled_collection) do
    SyncCollection.create!(title: "Release checklist").tap do |collection|
      github_issue.update!(sync_collection: collection)
      google_task.update!(sync_collection: collection)
      collection.update_mapping_provenance!(
        method: "title_fallback", confidence: "medium",
        metadata: { "matched_by" => "title" }, observed_at: mapping_observed_at
      )
    end
  end
  let(:unclear_collection) do
    SyncCollection.create!(title: "Unclear").tap do |collection|
      unclear_asana_task.update!(sync_collection: collection)
      unclear_omnifocus_task.update!(sync_collection: collection)
      collection.update_mapping_provenance!(
        method: "manual_backfill", confidence: "low", metadata: {}, observed_at: mapping_observed_at
      )
    end
  end

  before do
    omnifocus_class
    asana_class
    github_class
    google_tasks_class
    linked_collection
    titled_collection
    unclear_collection
    incomplete_item
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "baseline item snapshots" do
    it "enqueues one item row per complete existing item" do
      travel_to(backfilled_at) { described_class.run! }

      expect(item_rows.map(&:external_id)).to contain_exactly(
        "of-1", "asana-1", "issue-9", "gt-7", "asana-99", "of-99"
      )
    end

    it "writes no observation or sync-run rows" do
      travel_to(backfilled_at) { described_class.run! }

      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "uses the permanent service instance identities for each representative service" do
      travel_to(backfilled_at) { described_class.run! }

      expected_instances = {
        "of-1" => "omnifocus:default",
        "asana-1" => "asana:work",
        "issue-9" => "github:repo-1",
        "gt-7" => "google_tasks:default"
      }
      expected_instances.each do |external_id, service_instance|
        row = item_rows.find_by(external_id:)
        expect(row.service_instance).to eq(service_instance)
        expect(row.idempotency_key).to start_with("tb:v1:item:#{service_instance}:#{external_id}:snapshot:")
      end
    end

    it "carries the normalized snapshot with backfill markers, not change history" do
      travel_to(backfilled_at) { described_class.run! }

      row = item_rows.find_by(external_id: "asana-1")
      expect(row.observed_at).to eq(asana_task.last_observed_at)
      expect(row.payload).to include(
        "contract_version" => 1,
        "entity_type" => "task",
        "title" => "Ship the thing",
        "status" => "open",
        "is_deleted" => false
      )
      expect(row.payload["source"]).to include(
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "external_id" => "asana-1"
      )
      expect(row.payload["observed_at"]).to eq(asana_task.last_observed_at.utc.iso8601(6))
      expect(row.payload["event_type"]).to be_nil
      expect(row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => asana_task.last_observed_at.utc.iso8601(6)
      )
    end

    it "summarizes counts by service and skipped incomplete records" do
      summary = travel_to(backfilled_at) { described_class.run! }

      expect(summary.to_h[:items]).to include(
        enqueued: 6,
        existing: 0,
        skipped_incomplete: 1,
        by_service: including(
          "omnifocus" => 2,
          "asana" => 2,
          "github" => 1,
          "google_tasks" => 1
        )
      )
    end
  end

  describe "baseline mapping rows" do
    it "enqueues confirmed and inferred memberships with backfill markers" do
      travel_to(backfilled_at) { described_class.run! }

      expect(mapping_rows.count).to eq(4)
      confirmed = mapping_rows.where(sync_collection_id: linked_collection.id)
      expect(confirmed.map(&:external_id)).to contain_exactly("asana-1", "of-1")
      expect(confirmed.find_by(external_id: "asana-1").idempotency_key).to start_with(
        "tb:v1:map:sync_collection:#{linked_collection.id}:membership:asana:work:asana-1:"
      )
      confirmed.each do |row|
        expect(row.observed_at).to eq(mapping_observed_at)
        expect(row.payload["mapping_confidence"]).to eq("confirmed")
        expect(row.payload["mapping_source"]).to eq("sync_id_note")
        expect(row.payload["provenance"]).to include(
          "detected_by" => "backfill",
          "backfilled_at" => mapping_observed_at.utc.iso8601(6)
        )
      end

      inferred = mapping_rows.where(sync_collection_id: titled_collection.id)
      expect(inferred.map(&:external_id)).to contain_exactly("issue-9", "gt-7")
      inferred.each do |row|
        expect(row.payload["mapping_confidence"]).to eq("inferred")
        expect(row.payload["mapping_source"]).to eq("title_match")
        expect(row.payload["provenance"]).to include(
          "detected_by" => "backfill",
          "backfilled_at" => mapping_observed_at.utc.iso8601(6)
        )
      end
    end

    it "withholds low-confidence memberships but keeps them countable" do
      summary = travel_to(backfilled_at) { described_class.run! }

      expect(mapping_rows.where(sync_collection_id: unclear_collection.id)).to be_empty
      expect(summary.to_h[:mappings]).to include(
        enqueued: 4,
        withheld_low_confidence: 2,
        by_confidence: including("high" => 2, "medium" => 2, "low" => 2)
      )
    end
  end

  describe "idempotency" do
    it "does not duplicate rows when run repeatedly" do
      travel_to(backfilled_at) { described_class.run! }
      first_run_rows = OutboxEntry.all.to_a

      summary = travel_to(backfilled_at + 1.hour) { described_class.run! }

      expect(OutboxEntry.all.to_a).to contain_exactly(*first_run_rows)
      expect(summary.to_h[:items]).to include(enqueued: 0, existing: 6)
      expect(summary.to_h[:mappings]).to include(enqueued: 0, existing: 4)
    end

    it "does not re-baseline a membership the live pipeline already emitted" do
      live_collection = SyncCollection.create!(title: "Live emitted")
      live_collection.update_mapping_provenance!(
        method: "source_sync_id", confidence: "high", metadata: {}, observed_at: mapping_observed_at
      )
      github_issue.update!(sync_collection: live_collection)
      travel_to(mapping_observed_at) do
        Outbox::MappingEmitter.emit_for_members(live_collection, members: [github_issue])
      end

      summary = travel_to(backfilled_at) { described_class.run! }

      expect(mapping_rows.where(sync_collection_id: live_collection.id).count).to eq(1)
      expect(summary.to_h[:mappings]).to include(existing: 1)
    end

    it "leaves already-published baseline rows untouched on rerun" do
      travel_to(backfilled_at) { described_class.run! }
      row = item_rows.find_by(external_id: "gt-7")
      row.update_columns(status: "delivered", published_at: backfilled_at)

      travel_to(backfilled_at + 2.hours) { described_class.run! }

      reloaded = item_rows.find_by(external_id: "gt-7")
      expect(item_rows.where(external_id: "gt-7").count).to eq(1)
      expect(reloaded.payload).to eq(row.payload)
      expect(reloaded).to be_delivered
    end
  end

  describe "dry run" do
    it "writes nothing and reports the same counts a real run would" do
      summary = travel_to(backfilled_at) { described_class.run!(dry_run: true) }

      expect(OutboxEntry.count).to eq(0)
      expect(summary.format).to include("Outbox backfill dry run (nothing was enqueued)")
      expect(summary.to_h[:items]).to include(enqueued: 6, existing: 0, skipped_incomplete: 1)
      expect(summary.to_h[:mappings]).to include(enqueued: 4, withheld_low_confidence: 2)
    end

    it "previews real counts for legacy rows without writing their provenance" do
      legacy = omnifocus_class.create!(
        title: "Legacy row",
        external_id: "of-legacy",
        notes: "",
        options: item_options.merge(service_name: "Omnifocus")
      )
      legacy.update_columns(
        source_service_name: nil,
        source_service_instance: nil,
        source_service_type: nil,
        source_external_id: nil,
        source_url: nil,
        first_observed_at: nil,
        last_observed_at: nil
      )

      dry_summary = travel_to(backfilled_at) { described_class.run!(dry_run: true) }

      expect(legacy.reload.source_service_name).to be_nil
      expect(legacy.reload.last_observed_at).to be_nil

      real_summary = travel_to(backfilled_at) { described_class.run! }

      expect(legacy.reload.source_service_name).to eq("Omnifocus")
      expect(dry_summary.to_h[:items][:by_service]).to eq(real_summary.to_h[:items][:by_service])
      expect(dry_summary.to_h[:items][:enqueued]).to eq(real_summary.to_h[:items][:enqueued])
      expect(item_rows.find_by(external_id: "of-legacy").service_instance).to eq("omnifocus:default")
    end

    it "previews inferred confidence for collections without mapping metadata" do
      inferred_collection = SyncCollection.create!(title: "Fresh")
      asana_task.update!(sync_collection: inferred_collection)
      omnifocus_task.update!(sync_collection: inferred_collection)

      dry_summary = travel_to(backfilled_at) { described_class.run!(dry_run: true) }
      real_summary = travel_to(backfilled_at) { described_class.run! }

      expect(dry_summary.to_h[:mappings][:by_confidence]).to eq(real_summary.to_h[:mappings][:by_confidence])
      expect(dry_summary.to_h[:mappings][:by_confidence]).to include("high" => 2)
      expect(inferred_collection.reload.mapping_confidence).to eq("high")
    end
  end

  describe "safety" do
    it "never reads external data or mutates source records" do
      titles = Base::SyncItem.pluck(:id, :title)

      travel_to(backfilled_at) { described_class.run! }

      expect(Base::SyncItem.pluck(:id, :title)).to contain_exactly(*titles)
      expect(SyncServiceState.count).to eq(0)
    end

    it "does not bump observation timestamps on reruns" do
      travel_to(backfilled_at) { described_class.run! }
      observed_times = Base::SyncItem.pluck(:id, :last_observed_at)

      travel_to(backfilled_at + 1.day) { described_class.run! }

      expect(Base::SyncItem.pluck(:id, :last_observed_at)).to contain_exactly(*observed_times)
    end
  end
end
