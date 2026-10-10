# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineObservations do
  include ActiveSupport::Testing::TimeHelpers

  let(:item_options) do
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end
  let(:observed_at) { Time.zone.parse("2026-10-10T10:00:00Z") }

  # Representative providers per #222's acceptance criteria: OmniFocus,
  # Asana, GitHub, and Google Tasks.
  let(:omnifocus_item_class) do
    stub_const("BaselineOmnifocusItem", Class.new(Base::SyncItem) do
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
  let(:asana_item_class) do
    stub_const("BaselineAsanaItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        {}
      end
    end)
  end
  let(:github_item_class) do
    stub_const("BaselineGithubItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Github"
      end

      def external_data
        {}
      end
    end)
  end
  let(:google_tasks_item_class) do
    stub_const("BaselineGoogleTasksItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "GoogleTasks"
      end

      def external_data
        {}
      end
    end)
  end

  before do
    omnifocus_item_class
    asana_item_class
    github_item_class
    google_tasks_item_class
  end

  def create_item(item_class, external_id:, title: "Buy milk", sync_collection: nil)
    travel_to(observed_at) do
      item_class.create!(options: item_options, title:, external_id:, sync_collection:)
    end
  end

  def create_collection(mapping_confidence:, members:)
    collection = SyncCollection.create!(title: "Release checklist")
    members.each { |item| collection << item }
    collection.update_columns(mapping_confidence:, mapping_method: "source_sync_id")
    collection
  end

  def observation_rows
    OutboxEntry.where(record_kind: "observation").to_a
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping").to_a
  end

  describe "baseline item observations" do
    let!(:items) do
      [
        create_item(omnifocus_item_class, external_id: "of-1", title: "Buy milk"),
        create_item(asana_item_class, external_id: "asana-2", title: "Ship release"),
        create_item(github_item_class, external_id: "issue-42", title: "Fix bug"),
        create_item(google_tasks_item_class, external_id: "gt-7", title: "Call dentist")
      ]
    end

    it "emits one snapshot_seen row per existing item with baseline provenance" do
      summary = described_class.run!

      rows = observation_rows
      expect(rows.length).to eq(4)
      expect(rows.map(&:event_type).uniq).to eq(["snapshot_seen"])
      expect(rows.map { |row| row.payload["provenance"] }.uniq).to eq([{ "detected_by" => "baseline_backfill" }])
      expect(rows.map(&:observed_at).uniq).to eq([observed_at])
      expect(rows.map(&:idempotency_key)).to contain_exactly(
        "tb:v1:obs:omnifocus:of-1:snapshot_seen:2026-10-10T10:00:00.000000Z",
        "tb:v1:obs:asana:asana-2:snapshot_seen:2026-10-10T10:00:00.000000Z",
        "tb:v1:obs:github:issue-42:snapshot_seen:2026-10-10T10:00:00.000000Z",
        "tb:v1:obs:google_tasks:gt-7:snapshot_seen:2026-10-10T10:00:00.000000Z"
      )
      expect(summary[:items]).to include(
        "baseline" => 4, "skipped_incomplete" => 0, "already_observed" => 0,
        "by_service" => { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 }
      )
    end

    it "stores the diff baseline so later syncs emit true change history" do
      described_class.run!

      expect(items.map { |item| item.reload.last_snapshot }).to all(include("title"))

      travel_to(observed_at + 1.hour) do
        item = items.third.reload
        item.title = "Fix the bug"
        item.save!
        Outbox::ObservationEmitter.emit_for_item(item, previous_snapshot: item.last_snapshot)
      end

      changed = observation_rows.select { |row| row.payload.dig("change", "field") == "title" }
      expect(changed.map { |row| row.payload["change"] }).to eq([{ "field" => "title", "from" => "Fix bug", "to" => "Fix the bug" }])
      expect(observation_rows.select { |row| row.payload["event_type"] == "source_changed" })
        .to all(have_attributes(payload: hash_excluding("snapshot")))
    end

    it "does not touch the observed items beyond the local baseline column" do
      observed_before = items.map { |item| [item.id, item.last_observed_at] }

      described_class.run!

      expect(items.map { |item| [item.reload.id, item.last_observed_at] }).to eq(observed_before)
    end

    it "is idempotent across reruns" do
      described_class.run!
      second_summary = described_class.run!

      expect(observation_rows.length).to eq(4)
      expect(second_summary[:items]).to include("baseline" => 0, "already_observed" => 4)
    end

    it "reuses the same idempotency keys when a run is interrupted before the baseline advance" do
      described_class.run!
      Base::SyncItem.update_all(last_snapshot: nil) # simulate crash between enqueue and advance

      described_class.run!

      expect(observation_rows.length).to eq(4)
    end
  end

  describe "incomplete records" do
    it "counts items without an external id instead of emitting rows" do
      create_item(asana_item_class, external_id: "asana-1")
      create_item(github_item_class, external_id: nil)

      summary = described_class.run!

      expect(observation_rows.length).to eq(1)
      expect(summary[:items]).to include("baseline" => 1, "skipped_incomplete" => 1)
    end
  end

  describe "mapping observations" do
    let!(:confirmed_members) do
      [create_item(asana_item_class, external_id: "asana-1"),
       create_item(omnifocus_item_class, external_id: "of-1")]
    end
    let!(:tentative_members) do
      [create_item(github_item_class, external_id: "issue-9"),
       create_item(google_tasks_item_class, external_id: "gt-3")]
    end
    let!(:unmapped_members) do
      [create_item(asana_item_class, external_id: "asana-99"),
       create_item(omnifocus_item_class, external_id: "of-99")]
    end
    let!(:confirmed_collection) { create_collection(mapping_confidence: "high", members: confirmed_members) }
    let!(:tentative_collection) { create_collection(mapping_confidence: "low", members: tentative_members) }
    let!(:unmapped_collection) { create_collection(mapping_confidence: nil, members: unmapped_members) }

    before { confirmed_collection.update_columns(mapping_last_observed_at: observed_at) }

    it "publishes confirmed memberships and withholds tentative ones with counts" do
      summary = described_class.run!

      rows = mapping_rows
      expect(rows.length).to eq(2)
      expect(rows.map(&:record_kind).uniq).to eq(["mapping"])
      expect(rows.map { |row| row.payload["mapping_confidence"] }.uniq).to eq(["confirmed"])
      expect(rows.map { |row| row.payload["sync_collection"]["sync_collection_id"] }.uniq)
        .to eq([confirmed_collection.id])
      expect(rows.map(&:idempotency_key)).to contain_exactly(
        "tb:v1:map:sync_collection:#{confirmed_collection.id}:membership:asana:asana-1:#{observed_at.utc.iso8601(6)}",
        "tb:v1:map:sync_collection:#{confirmed_collection.id}:membership:omnifocus:of-1:#{observed_at.utc.iso8601(6)}"
      )
      expect(summary[:mappings]).to include(
        "published_members" => 2, "withheld_members" => 4, "skipped_incomplete_members" => 0,
        "withheld_collections_by_confidence" => { "low" => 1, "unmapped" => 1 }
      )
    end

    it "counts members without an external id as incomplete" do
      incomplete = create_item(github_item_class, external_id: nil)
      confirmed_collection << incomplete

      summary = described_class.run!

      expect(mapping_rows.length).to eq(2)
      expect(summary[:mappings]).to include("published_members" => 2, "skipped_incomplete_members" => 1)
    end

    it "is idempotent across reruns" do
      described_class.run!
      summary = described_class.run!

      expect(mapping_rows.length).to eq(2)
      expect(summary[:mappings]).to include("published_members" => 2)
    end
  end

  describe "dry run" do
    it "counts what would be emitted without writing anything" do
      asana_item = create_item(asana_item_class, external_id: "asana-1")
      create_item(github_item_class, external_id: nil)
      collection = create_collection(mapping_confidence: "high",
                                     members: [create_item(omnifocus_item_class, external_id: "of-1")])
      collection << asana_item

      summary = described_class.run!(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(Base::SyncItem.where.not(last_snapshot: nil).count).to eq(0)
      expect(summary[:items]).to include("baseline" => 2, "skipped_incomplete" => 1)
      expect(summary[:mappings]).to include("published_members" => 2)
    end
  end
end
