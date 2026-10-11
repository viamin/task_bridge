# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::MappingObservations, :full_options do
  %w[Asana Omnifocus Github GoogleTasks].each do |provider_name|
    let(:"#{provider_name.underscore}_item_class") do
      stub_const("MappingBackfill#{provider_name}Item", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        define_method(:provider) { provider_name }

        def external_data
          {}
        end
      end)
    end
  end

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  def create_item(klass, external_id:, title: "Release checklist")
    klass.create!(options:, title:, external_id:)
  end

  before do
    asana_item_class
    omnifocus_item_class
    github_item_class
    google_tasks_item_class
  end

  describe "#run! (representative services)" do
    it "publishes confirmed rows for high-confidence memberships, mapping high to confirmed" do
      collection = SyncCollection.create!(title: "Release checklist")
      github_item = create_item(github_item_class, external_id: "gh-1")
      google_item = create_item(google_tasks_item_class, external_id: "gt-1")
      [github_item, google_item].each { |item| item.update!(sync_collection: collection) }
      collection.update_mapping_provenance!(method: "source_sync_id", confidence: "high", observed_at:)

      summary = described_class.run!

      expect(summary[:enqueued]).to eq(2)
      expect(summary[:by_confidence]).to eq("high" => 2)
      rows = OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id)
      expect(rows.map(&:external_id)).to contain_exactly("gh-1", "gt-1")
      expect(rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
      expect(rows.map { |row| row.payload["mapping_source"] }).to all(eq("sync_id_note"))
      expect(rows.first.observed_at).to eq(observed_at)
    end

    it "publishes inferred rows for medium-confidence memberships, mapping medium to inferred" do
      collection = SyncCollection.create!(title: "Release checklist")
      asana_item = create_item(asana_item_class, external_id: "asana-1")
      omnifocus_item = create_item(omnifocus_item_class, external_id: "of-1")
      [asana_item, omnifocus_item].each { |item| item.update!(sync_collection: collection) }
      collection.update_mapping_provenance!(method: "title_fallback", confidence: "medium", observed_at:)

      described_class.run!

      rows = OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id)
      expect(rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      expect(rows.map { |row| row.payload["mapping_source"] }).to all(eq("title_match"))
    end

    it "withholds low-confidence memberships from publication but counts them in the summary" do
      collection = SyncCollection.create!(title: "Unlinked pair")
      asana_item = create_item(asana_item_class, external_id: "asana-2")
      github_item = create_item(github_item_class, external_id: "gh-2")
      [asana_item, github_item].each { |item| item.update!(sync_collection: collection) }
      collection.update_mapping_provenance!(method: "manual_backfill", confidence: "low", observed_at:)

      summary = described_class.run!

      expect(summary[:enqueued]).to eq(0)
      expect(summary[:skipped]["low_confidence_withheld"]).to eq(1)
      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id)).to be_empty
    end

    it "skips collections with fewer than two eligible members" do
      collection = SyncCollection.create!(title: "Solo", mapping_method: "source_sync_id", mapping_confidence: "high")
      only_member = create_item(github_item_class, external_id: "gh-solo")
      only_member.update!(sync_collection: collection)

      summary = described_class.run!

      expect(summary[:skipped]["insufficient_members"]).to eq(1)
      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
    end

    it "tags published rows as a backfill baseline, not a live detection" do
      collection = SyncCollection.create!(title: "Release checklist")
      first_item = create_item(github_item_class, external_id: "gh-3")
      second_item = create_item(google_tasks_item_class, external_id: "gt-3")
      [first_item, second_item].each { |item| item.update!(sync_collection: collection) }
      collection.update_mapping_provenance!(method: "source_sync_id", confidence: "high", observed_at:)

      described_class.run!

      row = OutboxEntry.find_by(record_kind: "mapping", external_id: "gh-3")
      expect(row.payload["provenance"]).to include("detected_by" => "backfill")
      expect(row.payload["provenance"]["backfilled_at"]).to be_present
    end
  end

  describe "idempotency" do
    it "can be run multiple times without duplicating or changing rows" do
      collection = SyncCollection.create!(title: "Release checklist")
      first_item = create_item(github_item_class, external_id: "gh-1")
      second_item = create_item(google_tasks_item_class, external_id: "gt-1")
      [first_item, second_item].each { |item| item.update!(sync_collection: collection) }
      collection.update_mapping_provenance!(method: "source_sync_id", confidence: "high", observed_at:)

      first_summary = described_class.run!
      first_rows = OutboxEntry.where(record_kind: "mapping").order(:external_id).to_a

      second_summary = described_class.run!
      second_rows = OutboxEntry.where(record_kind: "mapping").order(:external_id).to_a

      expect(second_summary[:enqueued]).to eq(first_summary[:enqueued])
      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
      expect(second_rows.map(&:idempotency_key)).to eq(first_rows.map(&:idempotency_key))
      expect(second_rows.map(&:payload)).to eq(first_rows.map(&:payload))
    end
  end

  describe "dry_run: true" do
    it "reports counts without writing any OutboxEntry rows" do
      collection = SyncCollection.create!(title: "Release checklist")
      first_item = create_item(github_item_class, external_id: "gh-1")
      second_item = create_item(google_tasks_item_class, external_id: "gt-1")
      [first_item, second_item].each { |item| item.update!(sync_collection: collection) }
      collection.update_mapping_provenance!(method: "source_sync_id", confidence: "high", observed_at:)

      summary = described_class.run!(dry_run: true)

      expect(summary[:enqueued]).to eq(2)
      expect(OutboxEntry.count).to eq(0)
    end
  end
end
