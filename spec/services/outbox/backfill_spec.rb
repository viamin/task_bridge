# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:observed_at) { Time.zone.parse("2026-10-10T08:00:00Z") }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  def create_item(klass, attributes)
    item_options = attributes.key?(:options) ? attributes.delete(:options) : options
    travel_to(observed_at) { klass.create!(attributes.merge(options: item_options)) }
  end

  def create_representative_items
    {
      omnifocus: create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-1", last_modified: observed_at),
      asana: create_item(
        Asana::Task,
        options: options.merge(service_name: "Asana:work"),
        title: "Ship release",
        external_id: "asana-1",
        last_modified: observed_at
      ),
      github: create_item(
        Github::Issue,
        title: "Fix sync bug",
        external_id: "gh-1",
        url: "https://github.com/viamin/task_bridge/issues/1",
        last_modified: observed_at
      ),
      google_tasks: create_item(GoogleTasks::Task, title: "Pick up groceries", external_id: "gt-1", last_modified: observed_at)
    }
  end

  describe "baseline item snapshots" do
    it "enqueues one marked item snapshot per existing item across services" do
      items = create_representative_items
      expect(items.values.map(&:persisted?)).to all(be true)

      summary = travel_to(now) { described_class.run! }

      rows = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(rows.keys).to contain_exactly("of-1", "asana-1", "gh-1", "gt-1")
      expect(rows.values.map(&:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:work", "github:default", "google_tasks:default"
      )
      expect(rows.values.map(&:status)).to all(eq("pending"))

      of_row = rows["of-1"]
      expect(of_row).to have_attributes(
        service_type: "omnifocus",
        observed_at: observed_at,
        source_updated_at: observed_at
      )
      expect(of_row.idempotency_key).to eq("tb:v1:item:omnifocus:default:of-1:snapshot:#{observed_at.utc.iso8601(6)}")
      expect(of_row.payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => observed_at.utc.iso8601(6)
      )
      expect(of_row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      )
      expect(of_row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => now.utc.iso8601(6)
      )
      expect(of_row.payload["notes_preview"]).to be_nil

      asana_row = rows["asana-1"]
      expect(asana_row.payload["source"]).to include("service_instance" => "asana:work", "external_id" => "asana-1")
      expect(asana_row.idempotency_key)
        .to eq("tb:v1:item:asana:work:asana-1:snapshot:#{observed_at.utc.iso8601(6)}")

      github_row = rows["gh-1"]
      expect(github_row.payload["source"]).to include(
        "service_instance" => "github:default",
        "source_url" => "https://github.com/viamin/task_bridge/issues/1"
      )
      # DB-loaded rows carry no in-memory github_issue payload; metadata
      # must stay nil-safe instead of raising.
      expect(github_row.payload["metadata"]).to eq({})

      expect(rows["gt-1"].payload["source"]).to include("service_instance" => "google_tasks:default")

      expect(summary.items).to include(enqueued: 4, skipped: 0)
      expect(summary.items[:by_service].keys).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
      expect(summary.mappings).to include(enqueued: 0, withheld: 0, skipped: 0)
    end

    it "emits no observation or sync_run rows" do
      create_representative_items

      travel_to(now) { described_class.run! }

      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
    end

    it "skips incomplete records without an external id and counts them" do
      create_item(Omnifocus::Task, title: "No external id", external_id: nil)

      summary = travel_to(now) { described_class.run! }

      expect(OutboxEntry.where(record_kind: "item")).to be_empty
      expect(summary.items).to include(enqueued: 0, skipped: 1)
      expect(summary.items[:by_service]["omnifocus"]).to include(skipped: 1)
    end

    it "seeds the stored diff baseline so a later unchanged refresh emits no discovery row" do
      item_class = stub_const("BackfillSpecItem", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        def provider
          "TestService"
        end

        def external_data
          @sync_item
        end
      end)
      item = travel_to(observed_at) do
        item_class.create!(
          sync_item: { "id" => "bf-1", "title" => "Buy milk", "completed" => false },
          options:,
          external_id: "bf-1",
          title: "Buy milk",
          completed: false
        )
      end

      travel_to(now) { described_class.run! }

      expect(item.reload.last_snapshot).to include(
        "title" => "Buy milk",
        "item_key" => "test_service:bf-1"
      )

      expect do
        travel_to(now + 1.hour) do
          # Refresh through a freshly loaded instance, exactly like a live
          # sync run would, so options-derived fields (tags) match the
          # instance whose snapshot seeded the baseline.
          fresh = item_class.find(item.id)
          fresh.instance_variable_set(:@sync_item, { "id" => "bf-1", "title" => "Buy milk", "completed" => false })
          fresh.refresh_from_external!
        end
      end.not_to(change { OutboxEntry.where(record_kind: "observation").count })
    end

    it "never clobbers a diff baseline the live pipeline already stored" do
      item = create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-1")
      item.update_column(:last_snapshot, { "title" => "Already observed" })

      travel_to(now) { described_class.run! }

      expect(item.reload.last_snapshot).to eq("title" => "Already observed")
    end
  end

  describe "mapping memberships" do
    let(:high_collection) do
      SyncCollection.create!(
        title: "Sync-id linked",
        mapping_method: "source_sync_id",
        mapping_confidence: "high",
        mapping_last_observed_at: observed_at
      )
    end
    let(:medium_collection) do
      SyncCollection.create!(
        title: "Title matched",
        mapping_method: "title_fallback",
        mapping_confidence: "medium",
        mapping_last_observed_at: observed_at
      )
    end
    let(:low_collection) do
      SyncCollection.create!(
        title: "Manual guess",
        mapping_method: "manual_backfill",
        mapping_confidence: "low",
        mapping_last_observed_at: observed_at
      )
    end
    let(:unlabelled_collection) do
      SyncCollection.create!(title: "Legacy", mapping_last_observed_at: observed_at)
    end

    before do
      create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-1", sync_collection: high_collection)
      create_item(
        Asana::Task,
        options: options.merge(service_name: "Asana:work"),
        title: "Buy milk",
        external_id: "asana-1",
        sync_collection: high_collection
      )
      create_item(
        Github::Issue,
        title: "Buy milk",
        external_id: "gh-1",
        sync_collection: medium_collection
      )
      create_item(GoogleTasks::Task, title: "Buy milk", external_id: "gt-1", sync_collection: medium_collection)
      create_item(Omnifocus::Task, title: "Maybe", external_id: "of-9", sync_collection: low_collection)
      create_item(Omnifocus::Task, title: "Legacy", external_id: "of-10", sync_collection: unlabelled_collection)
    end

    it "enqueues only confirmed and inferred memberships, withholding low and unknown ones" do
      summary = travel_to(now) { described_class.run! }

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.map(&:external_id)).to contain_exactly("of-1", "asana-1", "gh-1", "gt-1")
      expect(rows.map(&:sync_collection_id)).to contain_exactly(high_collection.id, high_collection.id,
                                                                medium_collection.id, medium_collection.id)

      confirmed = rows.find { |row| row.external_id == "of-1" }
      expect(confirmed).to have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default")
      expect(confirmed.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{high_collection.id}:membership:omnifocus:default:of-1:#{observed_at.utc.iso8601(6)}"
      )
      expect(confirmed.payload).to include(
        "mapping_type" => "representation_membership",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(confirmed.payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill"
      )

      inferred = rows.find { |row| row.external_id == "gh-1" }
      expect(inferred.payload).to include("mapping_confidence" => "inferred", "mapping_source" => "title_match")

      expect(summary.mappings).to include(enqueued: 4, withheld: 2, skipped: 0)
      expect(summary.mappings[:by_confidence]).to include(
        "high" => including(enqueued: 2),
        "medium" => including(enqueued: 2),
        "low" => including(withheld: 1),
        "unknown" => including(withheld: 1)
      )
      expect(summary.withheld_members).to contain_exactly(
        including(sync_collection_id: low_collection.id, item_key: "omnifocus:of-9", confidence: "low"),
        including(sync_collection_id: unlabelled_collection.id, item_key: "omnifocus:of-10", confidence: "unknown")
      )
    end

    it "counts members without an external id as skipped" do
      create_item(Github::Issue, title: "Incomplete", external_id: nil, sync_collection: high_collection)

      summary = travel_to(now) { described_class.run! }

      expect(summary.mappings).to include(skipped: 1)
      expect(summary.mappings[:by_confidence]["high"]).to include(skipped: 1)
    end
  end

  describe "idempotency" do
    it "does not duplicate rows when run again after live activity bumped timestamps" do
      item = create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-1", last_modified: observed_at)
      collection = SyncCollection.create!(
        title: "Linked",
        mapping_method: "source_sync_id",
        mapping_confidence: "high",
        mapping_last_observed_at: observed_at
      )
      item.update!(sync_collection: collection)
      create_item(Asana::Task, title: "Buy milk", external_id: "asana-1", sync_collection: collection)

      travel_to(now) { described_class.run! }
      first_keys = OutboxEntry.order(:id).pluck(:idempotency_key)
      expect(first_keys.length).to eq(4)

      item.update_column(:last_observed_at, now)
      collection.update_column(:mapping_last_observed_at, now)

      summary = travel_to(now + 1.hour) { described_class.run! }

      expect(OutboxEntry.order(:id).pluck(:idempotency_key)).to eq(first_keys)
      expect(summary.items).to include(enqueued: 0)
      expect(summary.mappings).to include(enqueued: 0)
    end
  end

  describe "safety" do
    it "writes only outbox rows and diff baselines, never source system state" do
      asana_item = create_item(
        Asana::Task,
        options: options.merge(service_name: "Asana:work"),
        title: "Ship release",
        external_id: "asana-1",
        notes: "omnifocus_id: of-1",
        last_modified: observed_at
      )
      watched = asana_item.reload.slice(
        :external_id, :title, :notes, :last_modified, :source_updated_at, :source_service_name, :source_service_instance
      )

      expect { travel_to(now) { described_class.run! } }
        .not_to change { asana_item.reload.slice(*watched.keys) }.from(watched)
      expect(SyncServiceState.count).to eq(0)
    end
  end

  describe "dry run" do
    it "writes nothing while summarizing exactly what a real run would enqueue" do
      items = create_representative_items
      collection = SyncCollection.create!(
        title: "Manual guess",
        mapping_method: "manual_backfill",
        mapping_confidence: "low",
        mapping_last_observed_at: observed_at
      )
      items[:omnifocus].update!(sync_collection: collection)

      summary = travel_to(now) { described_class.run!(dry_run: true) }

      expect(OutboxEntry.count).to eq(0)
      expect(items.values.map { |item| item.reload.last_snapshot }).to all(be_nil)

      expect(summary.dry_run?).to be true
      expect(summary.items).to include(enqueued: 4, skipped: 0)
      expect(summary.mappings).to include(withheld: 1)
      expect(summary.withheld_members).to contain_exactly(including(item_key: "omnifocus:of-1", confidence: "low"))

      travel_to(now) { described_class.run! }
      expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    end

    it "renders counts by service and confidence plus the withheld membership list" do
      create_representative_items
      collection = SyncCollection.create!(
        title: "Manual guess",
        mapping_method: "manual_backfill",
        mapping_confidence: "low",
        mapping_last_observed_at: observed_at
      )
      Omnifocus::Task.find_by(external_id: "of-1").update!(sync_collection: collection)

      rendered = travel_to(now) { described_class.run!(dry_run: true).render }

      expect(rendered).to include("(dry run: nothing was written)")
      expect(rendered).to include("item snapshots by service:")
      expect(rendered).to include("omnifocus: 1 enqueued, 0 skipped")
      expect(rendered).to include("asana: 1 enqueued, 0 skipped")
      expect(rendered).to include("mapping memberships by confidence:")
      expect(rendered).to include("low: 0 enqueued, 1 withheld, 0 skipped")
      expect(rendered).to include("withheld memberships held back from publication")
      expect(rendered).to include("SyncCollection ##{collection.id} \"Manual guess\" member omnifocus:of-1")
      expect(rendered).to include("confidence: low, method: manual_backfill")
    end
  end
end
