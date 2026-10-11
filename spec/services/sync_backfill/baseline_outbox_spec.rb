# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox do
  include ActiveSupport::Testing::TimeHelpers

  # Every external accessor raises: the backfill must derive baseline rows
  # purely from local database state (#222: backfill never mutates external
  # source systems).
  def stub_item_class(provider)
    stub_const("Baseline#{provider.delete(':').camelize}Item", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def external_data
        raise "backfill must not read external sources"
      end

      def read_original(*)
        raise "backfill must not read external sources"
      end

      def refresh_from_external!(*)
        raise "backfill must not read external sources"
      end
    end).tap do |klass|
      klass.define_method(:provider) { provider }
    end
  end

  let(:options) do
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end
  let(:asana_class) { stub_item_class("Asana") }
  let(:omnifocus_class) { stub_item_class("Omnifocus") }
  let(:github_class) { stub_item_class("Github") }
  let(:google_tasks_class) { stub_item_class("GoogleTasks") }

  def create_item(klass, service_name:, external_id:, **attributes)
    defaults = { title: "Buy milk", notes: "", sync_collection: nil }
    klass.create!(defaults.merge(attributes).merge(options: options.merge(service_name:), external_id:))
  end

  # OmniFocus <-> Asana linked through sync-id notes: ID-derived mapping.
  let(:confirmed_collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high",
                           mapping_last_observed_at: Time.zone.parse("2026-10-04T09:00:00Z"))
  end
  # GitHub <-> Google Tasks linked only by matching titles: title-derived.
  let(:inferred_collection) do
    SyncCollection.create!(title: "Release checklist", mapping_method: "title_fallback", mapping_confidence: "medium",
                           mapping_last_observed_at: Time.zone.parse("2026-10-04T09:30:00Z"))
  end
  # No evidence linking the single member: low confidence, withheld.
  let(:withheld_collection) do
    SyncCollection.create!(title: "Untitled", mapping_method: "manual_backfill", mapping_confidence: "low",
                           mapping_last_observed_at: Time.zone.parse("2026-10-04T08:00:00Z"))
  end
  let(:asana_item) do
    create_item(asana_class, service_name: "Asana:work", external_id: "asana-1",
                             notes: "omnifocus_id: of-1", sync_collection: confirmed_collection)
  end
  let(:omnifocus_item) do
    create_item(omnifocus_class, service_name: "Omnifocus", external_id: "of-1",
                                 notes: "asana_work_id: asana-1", sync_collection: confirmed_collection)
  end
  let(:github_item) do
    create_item(github_class, service_name: "Github", external_id: "issue-42",
                              sync_collection: inferred_collection)
  end
  let(:google_tasks_item) do
    create_item(google_tasks_class, service_name: "GoogleTasks", external_id: "gtask-7",
                                    sync_collection: inferred_collection)
  end
  let(:withheld_item) do
    create_item(github_class, service_name: "Github", external_id: "issue-99",
                              title: "Untitled", sync_collection: withheld_collection)
  end
  let(:incomplete_item) do
    create_item(google_tasks_class, service_name: "GoogleTasks", external_id: nil, title: "No id")
  end

  before do
    travel_to(Time.zone.parse("2026-10-05T10:00:00Z"))
    asana_item
    omnifocus_item
    github_item
    google_tasks_item
    withheld_item
    incomplete_item
  end

  after { travel_back }

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "#run!" do
    it "enqueues one baseline item snapshot per item with representative identities" do
      described_class.run!

      expect(item_rows.count).to eq(5)
      expect(item_rows.find_by(external_id: "of-1")).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        observed_at: omnifocus_item.last_observed_at
      )
      expect(item_rows.find_by(external_id: "asana-1").service_instance).to eq("asana:work")
      expect(item_rows.find_by(external_id: "issue-42").service_instance).to eq("github:default")
      expect(item_rows.find_by(external_id: "gtask-7").service_instance).to eq("google_tasks:default")
      expect(item_rows.find_by(external_id: "issue-99").service_instance).to eq("github:default")
      expect(item_rows.map(&:idempotency_key)).to all(match(/\Atb:v1:item:.+:snapshot:\d{4}-\d{2}-\d{2}T.+\z/))
    end

    it "links item rows to their sync collection" do
      described_class.run!

      expect(item_rows.find_by(external_id: "of-1").sync_collection_id).to eq(confirmed_collection.id)
      expect(item_rows.find_by(external_id: "gtask-7").sync_collection_id).to eq(inferred_collection.id)
    end

    it "marks item snapshots as baseline facts, not historical events" do
      described_class.run!

      row = item_rows.find_by(external_id: "of-1")
      expect(row.payload).to include(
        "contract_version" => 1,
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1"
      )
      expect(row.payload["provenance"]).to include("detected_by" => "backfill")
      expect(row.payload["provenance"]["backfilled_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      # Item-only baseline (#222 clarification): no fabricated observations.
      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
    end

    it "uses a deterministic observed_at so reruns reuse the same item key" do
      described_class.run!
      key = item_rows.find_by(external_id: "of-1").idempotency_key

      travel_to(Time.zone.parse("2026-10-06T10:00:00Z")) { described_class.run! }

      expect(item_rows.find_by(external_id: "of-1").idempotency_key).to eq(key)
      expect(item_rows.count).to eq(5)
    end

    it "enqueues mapping rows only for confirmed and inferred memberships" do
      described_class.run!

      confirmed = mapping_rows.where(sync_collection_id: confirmed_collection.id)
      expect(confirmed.map(&:external_id)).to contain_exactly("asana-1", "of-1")
      expect(confirmed.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
      expect(confirmed.map { |row| row.payload["provenance"]["detected_by"] }).to all(eq("backfill"))

      inferred = mapping_rows.where(sync_collection_id: inferred_collection.id)
      expect(inferred.map(&:external_id)).to contain_exactly("issue-42", "gtask-7")
      expect(inferred.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      expect(inferred.map { |row| row.payload["mapping_source"] }).to all(eq("title_match"))
    end

    it "marks backfilled mapping rows with backfilled_at metadata" do
      described_class.run!

      provenance = mapping_rows.find_by(external_id: "of-1").payload["provenance"]
      expect(provenance).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill"
      )
      expect(provenance["backfilled_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "seeds the diff baseline so later live observations publish only diffs" do
      described_class.run!

      reloaded = omnifocus_class.find(omnifocus_item.id)
      expect(reloaded.last_snapshot).to include("item_key" => reloaded.item_key, "title" => "Buy milk")

      # The live pipeline now diffs against the backfilled baseline: an
      # unchanged item must not re-emit the baseline as snapshot_seen.
      rows = Outbox::ObservationEmitter.emit_for_item(reloaded, previous_snapshot: reloaded.last_snapshot)

      expect(rows).to eq([])
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end

    it "never overwrites an existing diff baseline" do
      omnifocus_item.update_columns(last_snapshot: { "title" => "Stale baseline" })

      described_class.run!

      expect(omnifocus_item.reload.last_snapshot).to include("title" => "Stale baseline")
    end

    it "does not re-enqueue unchanged mappings on rerun" do
      described_class.run!

      expect { travel_to(Time.zone.parse("2026-10-06T10:00:00Z")) { described_class.run! } }
        .not_to(change { mapping_rows.count })
    end

    it "reports withheld low-confidence mappings and skipped records by service and confidence" do
      summary = described_class.run!

      expect(mapping_rows.where(sync_collection_id: withheld_collection.id)).to be_empty
      expect(summary.to_h).to include(
        dry_run: false,
        items: a_hash_including(
          enqueued: { total: 5, by_service: { "Asana:work" => 1, "Github" => 2, "GoogleTasks" => 1, "Omnifocus" => 1 } },
          skipped: { total: 1, by_service: { "GoogleTasks" => 1 }, by_reason: { "missing_external_id" => 1 } }
        ),
        mappings: a_hash_including(
          enqueued: { total: 4, by_confidence: { "high" => 2, "medium" => 2 } },
          withheld: {
            total: 1,
            by_confidence: { "low" => 1 },
            sync_collections: [
              { "sync_collection_id" => withheld_collection.id, "title" => "Untitled", "members" => 1 }
            ]
          },
          skipped: { total: 0, by_reason: {} }
        )
      )
      expect(summary.to_s).to include("withheld from publication: 1", "Untitled")
    end

    it "does not touch external source systems or advance item observation state" do
      observed_at = omnifocus_item.last_observed_at

      described_class.run!

      expect(omnifocus_item.reload.last_observed_at).to eq(observed_at)
      expect(incomplete_item.reload.external_id).to be_nil
    end
  end

  describe ".run!(dry_run: true)" do
    it "writes nothing and reports the counts the backfill would produce" do
      summary = described_class.run!(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(summary.to_h).to include(
        dry_run: true,
        items: a_hash_including(
          enqueued: { total: 5, by_service: { "Asana:work" => 1, "Github" => 2, "GoogleTasks" => 1, "Omnifocus" => 1 } },
          skipped: { total: 1, by_service: { "GoogleTasks" => 1 }, by_reason: { "missing_external_id" => 1 } }
        ),
        mappings: a_hash_including(
          enqueued: { total: 4, by_confidence: { "high" => 2, "medium" => 2 } },
          withheld: a_hash_including(total: 1, by_confidence: { "low" => 1 })
        )
      )
    end

    it "previews provenance backfill effects on legacy rows without persisting them" do
      # Simulate pre-#216/#217 data: no explicit provenance anywhere.
      [asana_item, omnifocus_item].each do |item|
        item.update_columns(
          source_service_name: nil, source_service_instance: nil, source_service_type: nil,
          source_external_id: nil, source_url: nil, source_created_at: nil, source_updated_at: nil,
          first_observed_at: nil, last_observed_at: nil, source_metadata: nil, last_snapshot: nil
        )
      end
      confirmed_collection.update_columns(
        mapping_method: nil, mapping_confidence: nil, mapping_metadata: nil,
        mapping_established_at: nil, mapping_last_observed_at: nil
      )

      summary = described_class.run!(dry_run: true)

      # The sync-id notes linking asana_item/omnifocus_item would upgrade
      # the collection to ID-derived (high confidence) mappings — the
      # preview reports that outcome instead of reporting the rows as
      # skipped.
      expect(summary.to_h).to include(
        dry_run: true,
        items: a_hash_including(
          enqueued: { total: 5, by_service: { "Asana:work" => 1, "Github" => 2, "GoogleTasks" => 1, "Omnifocus" => 1 } },
          skipped: { total: 1, by_service: { "GoogleTasks" => 1 }, by_reason: { "missing_external_id" => 1 } }
        ),
        mappings: a_hash_including(
          enqueued: { total: 4, by_confidence: { "high" => 2, "medium" => 2 } },
          withheld: a_hash_including(total: 1, by_confidence: { "low" => 1 })
        )
      )
      expect(OutboxEntry.count).to eq(0)
      expect(asana_item.reload.source_service_name).to be_nil
      expect(omnifocus_item.reload.last_snapshot).to be_nil

      write_summary = described_class.run!
      expect(write_summary.to_h[:mappings]).to eq(summary.to_h[:mappings])
      expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
      expect(confirmed_collection.reload.mapping_confidence).to eq("high")
    end

    it "reports memberships whose mapping confidence is unknown as skipped" do
      SyncCollection.update_all(mapping_confidence: nil)
      travel_to(Time.zone.parse("2026-10-04T07:00:00Z")) { SyncCollection.update_all(updated_at: Time.current) }

      summary = described_class.run!(dry_run: true)

      expect(summary.to_h[:mappings][:enqueued][:total]).to eq(0)
      expect(summary.to_h[:mappings][:skipped]).to include(total: 5, by_reason: { "missing_mapping_confidence" => 5 })
    end
  end
end
