# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  let(:omnifocus_class) do
    stub_const("BaselineOmnifocusTask", Class.new(Base::SyncItem) do
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
  let(:asana_class) do
    stub_const("BaselineAsanaTask", Class.new(Base::SyncItem) do
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
  let(:github_class) do
    stub_const("BaselineGithubIssue", Class.new(Base::SyncItem) do
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
  let(:google_tasks_class) do
    stub_const("BaselineGoogleTasksTask", Class.new(Base::SyncItem) do
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
  let(:item_options) { { services: [], primary: "Omnifocus", tags: [] } }

  before do
    omnifocus_class
    asana_class
    github_class
    google_tasks_class
  end

  describe ".run!" do
    it "publishes baseline item snapshots for representative services" do
      asana_class.create!(title: "Buy milk", external_id: "asana-1", options: item_options.merge(service_name: "Asana:work"))
      omnifocus_class.create!(title: "Buy milk", external_id: "of-1", options: item_options.merge(service_name: "Omnifocus"))
      github_class.create!(title: "Buy milk", external_id: "issue-1", options: item_options.merge(service_name: "Github"))
      google_tasks_class.create!(title: "Buy milk", external_id: "gt-1", options: item_options.merge(service_name: "GoogleTasks"))

      summary = described_class.run!

      rows = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(rows.keys).to contain_exactly("asana-1", "of-1", "issue-1", "gt-1")
      expect(rows["asana-1"]).to have_attributes(service_type: "asana", service_instance: "asana:work")
      expect(rows["of-1"]).to have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default")
      expect(rows["issue-1"]).to have_attributes(service_type: "github", service_instance: "github:default")
      expect(rows["gt-1"]).to have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")
      rows.each_value do |row|
        expect(row.payload["provenance"]).to include("detected_by" => "backfill", "backfilled_at" => row.payload["observed_at"])
        expect(row.payload["title"]).to eq("Buy milk")
      end
      expect(summary.to_h[:items]).to include(planned: 4, skipped_incomplete: 0)
      expect(summary.to_h[:items][:by_service]).to include(
        "asana" => { planned: 1, skipped_incomplete: 0 },
        "omnifocus" => { planned: 1, skipped_incomplete: 0 },
        "github" => { planned: 1, skipped_incomplete: 0 },
        "google_tasks" => { planned: 1, skipped_incomplete: 0 }
      )
    end

    it "marks the observed state at the item's stable observation time" do
      observed_at = Time.zone.parse("2026-10-01T08:00:00Z")
      item = omnifocus_class.create!(title: "Buy milk", external_id: "of-1", options: item_options.merge(service_name: "Omnifocus"))
      item.update_columns(last_observed_at: observed_at, updated_at: observed_at)

      described_class.run!

      row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
      expect(row.observed_at).to eq(observed_at)
      expect(row.idempotency_key).to eq("tb:v1:item:omnifocus:default:of-1:snapshot:#{observed_at.utc.iso8601(6)}")
    end

    it "is idempotent across reruns" do
      seed_data
      described_class.run!
      first_rows = OutboxEntry.all.to_a

      summary = described_class.run!

      expect(OutboxEntry.all.to_a).to match_array(first_rows)
      expect(summary.to_h[:items][:planned]).to eq(4)
    end

    it "recreates identical rows after delivered rows were pruned" do
      seed_data
      original_rows = described_class.run!.then { OutboxEntry.all.to_a }
      OutboxEntry.update_all(status: "delivered", published_at: Time.current)
      OutboxEntry.delete_all

      described_class.run!

      expect(OutboxEntry.all.to_a.map(&:idempotency_key)).to match_array(original_rows.map(&:idempotency_key))
      expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-1").payload)
        .to eq(original_rows.find { |row| row.record_kind == "item" && row.external_id == "of-1" }.payload)
    end

    it "backfills source provenance before publishing" do
      legacy_item = omnifocus_class.create!(title: "Legacy", external_id: "of-legacy", options: item_options.merge(service_name: "Omnifocus"))
      legacy_item.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, first_observed_at: nil, last_observed_at: nil
      )

      described_class.run!

      expect(legacy_item.reload.source_service_name).to eq("Omnifocus")
      expect(legacy_item.last_observed_at).to be_present
      expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-legacy")).to be_present
    end

    it "skips incomplete records and reports them" do
      asana_class.create!(title: "No id", external_id: nil, options: item_options.merge(service_name: "Asana"))

      summary = described_class.run!

      expect(OutboxEntry.where(record_kind: "item")).to be_empty
      expect(summary.to_h[:items]).to include(planned: 0, skipped_incomplete: 1)
      expect(summary.to_h[:items][:by_service]).to include("asana" => { planned: 0, skipped_incomplete: 1 })
    end
  end

  describe "mapping backfill" do
    it "publishes confirmed and inferred memberships and withholds low-confidence ones" do
      confirmed = confirmed_collection
      inferred = inferred_collection
      withheld = withheld_collection
      incomplete_member = github_class.create!(title: "No id", external_id: nil, options: item_options.merge(service_name: "Github"))
      confirmed.sync_items << incomplete_member

      summary = described_class.run!

      published = OutboxEntry.where(record_kind: "mapping")
      expect(published.map(&:sync_collection_id)).to contain_exactly(confirmed.id, confirmed.id, inferred.id, inferred.id)
      expect(published.where(sync_collection_id: confirmed.id).map(&:payload).map { |payload| payload["mapping_confidence"] })
        .to all(eq("confirmed"))
      expect(published.where(sync_collection_id: inferred.id).map(&:payload).map { |payload| payload["mapping_confidence"] })
        .to all(eq("inferred"))
      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: withheld.id)).to be_empty

      mappings = summary.to_h[:mappings]
      expect(mappings).to include(planned: 4, withheld: 2, skipped_incomplete: 1)
      expect(mappings[:by_confidence]).to eq("confirmed" => 2, "inferred" => 2, "tentative" => 2)
      expect(mappings[:withheld_memberships]).to contain_exactly(
        hash_including(
          sync_collection_id: withheld.id,
          member_item_key: "asana_work:asana-low",
          mapping_method: "manual_backfill",
          mapping_confidence: "tentative"
        ),
        hash_including(sync_collection_id: withheld.id, member_item_key: "omnifocus:of-low")
      )
    end

    it "keeps withheld memberships reviewable in the formatted summary" do
      withheld = withheld_collection

      output = described_class.run!.format

      expect(output).to include("Mappings: 0 planned, 2 withheld low-confidence, 0 skipped incomplete")
      expect(output).to include("Mappings by confidence: tentative: 2")
      expect(output).to include("sync_collection #{withheld.id}")
      expect(output).to include("asana_work:asana-low (manual_backfill)")
    end
  end

  describe ".preview" do
    it "plans the same rows as run! without writing anything" do
      seed_data
      confirmed_collection

      preview_summary = described_class.preview

      expect(OutboxEntry.count).to eq(0)
      expect(preview_summary.to_h[:items][:planned]).to eq(6)
      expect(preview_summary.to_h[:mappings][:planned]).to eq(2)

      run_summary = described_class.run!
      expect(run_summary.to_h[:items][:planned]).to eq(preview_summary.to_h[:items][:planned])
      expect(OutboxEntry.where(record_kind: "item").count).to eq(6)
    end

    it "does not backfill source provenance" do
      item = omnifocus_class.create!(title: "Legacy", external_id: "of-1", options: item_options.merge(service_name: "Omnifocus"))
      item.update_columns(last_observed_at: nil, source_service_name: nil)

      described_class.preview

      expect(item.reload.last_observed_at).to be_nil
      expect(item.source_service_name).to be_nil
    end
  end

  def seed_data
    asana_class.create!(title: "Buy milk", external_id: "asana-1", options: item_options.merge(service_name: "Asana:work"))
    omnifocus_class.create!(title: "Buy milk", external_id: "of-1", options: item_options.merge(service_name: "Omnifocus"))
    github_class.create!(title: "Sync engine", external_id: "issue-1", options: item_options.merge(service_name: "Github"))
    google_tasks_class.create!(title: "Buy milk", external_id: "gt-1", options: item_options.merge(service_name: "GoogleTasks"))
  end

  def confirmed_collection
    collection = SyncCollection.create!(title: "Release checklist")
    collection.sync_items << asana_class.create!(
      title: "Release checklist", external_id: "asana-high",
      notes: "omnifocus_id: of-high", options: item_options.merge(service_name: "Asana:work")
    )
    collection.sync_items << omnifocus_class.create!(
      title: "Release checklist", external_id: "of-high",
      notes: "asana_work_id: asana-high", options: item_options.merge(service_name: "Omnifocus")
    )
    collection.update_mapping_provenance!(method: "source_sync_id", confidence: "high", observed_at: Time.zone.parse("2026-10-01T09:00:00Z"))
    collection
  end

  def inferred_collection
    collection = SyncCollection.create!(title: "Buy milk")
    collection.sync_items << asana_class.create!(title: "Buy milk", external_id: "asana-medium", options: item_options.merge(service_name: "Asana:work"))
    collection.sync_items << omnifocus_class.create!(title: "Buy milk", external_id: "of-medium", options: item_options.merge(service_name: "Omnifocus"))
    collection.update_mapping_provenance!(method: "title_fallback", confidence: "medium", observed_at: Time.zone.parse("2026-10-01T09:00:00Z"))
    collection
  end

  def withheld_collection
    collection = SyncCollection.create!(title: "Maybe linked")
    collection.sync_items << asana_class.create!(title: "Unrelated", external_id: "asana-low", options: item_options.merge(service_name: "Asana:work"))
    collection.sync_items << omnifocus_class.create!(title: "Something else", external_id: "of-low", options: item_options.merge(service_name: "Omnifocus"))
    collection.update_mapping_provenance!(method: "manual_backfill", confidence: "low", observed_at: Time.zone.parse("2026-10-01T09:00:00Z"))
    collection
  end
end
