# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  let(:options) { { services: [], primary: "Asana", tags: [], pretend: false } }

  let(:item_class) do
    stub_const("OutboxBaselineSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        source_service_type || "Asana"
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(provider:, external_id:, collection:, service_name: provider)
    item_class.create!(
      title: "#{provider} task",
      external_id:,
      notes: "",
      sync_collection: collection,
      source_service_type: provider,
      options: options.merge(service_name:)
    )
  end

  before { item_class }

  it "seeds baseline snapshots and publishable mappings for representative services" do
    collection = SyncCollection.create!(title: "Release work")
    items = [
      create_item(provider: "Omnifocus", external_id: "of-1", collection:),
      create_item(provider: "Asana", external_id: "asana-1", collection:, service_name: "Asana:work"),
      create_item(provider: "Github", external_id: "gh-1", collection:),
      create_item(provider: "Google Tasks", external_id: "gt-1", collection:)
    ]
    items.first.update!(notes: "asana_work_id: asana-1")

    described_class.run!(io: StringIO.new)

    snapshots = OutboxEntry.where(record_kind: "item")
    mappings = OutboxEntry.where(record_kind: "mapping")
    expect(snapshots.pluck(:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
    expect(snapshots.find_by(external_id: "of-1")).to have_attributes(service_instance: "omnifocus:default")
    expect(snapshots.find_by(external_id: "asana-1").payload).to include(
      "contract_version" => 1,
      "provenance" => hash_including("detected_by" => "backfill", "backfilled_at" => be_present)
    )
    expect(snapshots.find_by(external_id: "asana-1").payload["observed_at"]).to be_present
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(mappings.count).to eq(4)
    expect(mappings.pluck(:payload).map { |payload| payload["mapping_confidence"] }).to all(eq("confirmed"))
  end

  it "withholds low-confidence memberships and reports them during dry runs" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(provider: "Github", external_id: "gh-low", collection:)
    output = StringIO.new

    described_class.run!(dry_run: true, io: output)

    expect(OutboxEntry.count).to eq(0)
    expect(output.string).to include("items by service: github=1")
    expect(output.string).to include("skipped mappings: low=1")
    expect(collection.reload.mapping_method).to eq("manual_backfill")
  end

  it "is idempotent when rerun" do
    collection = SyncCollection.create!(title: "Single")
    create_item(provider: "Asana", external_id: "asana-only", collection:)

    described_class.run!(io: StringIO.new)
    first_keys = OutboxEntry.pluck(:idempotency_key)
    described_class.run!(io: StringIO.new)

    expect(OutboxEntry.pluck(:idempotency_key)).to match_array(first_keys)
  end
end
