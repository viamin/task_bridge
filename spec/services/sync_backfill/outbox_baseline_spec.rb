# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  let(:output) { StringIO.new }
  let(:item_classes) do
    {
      omnifocus: backfill_item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: backfill_item_class("BackfillAsanaItem", "Asana"),
      github: backfill_item_class("BackfillGithubItem", "Github"),
      google_tasks: backfill_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  before { item_classes }

  it "backfills one baseline snapshot for each supported source idempotently" do
    items = item_classes.map do |service, item_class|
      item_class.create!(title: service.to_s, external_id: "#{service}-1", options: options)
    end

    described_class.run!(output:)
    described_class.run!(output:)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance))
      .to contain_exactly("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
    expect(OutboxEntry.where(record_kind: "item").map { |entry| entry.payload.dig("provenance", "detected_by") })
      .to all(eq("backfill"))
    expect(items.map { |item| item.reload.last_observed_at }).to all(be_present)
  end

  it "publishes inferred mappings and withholds tentative mappings" do
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    tentative = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    item_classes[:asana].create!(title: "Inferred", external_id: "asana-1", sync_collection: inferred, options: options)
    item_classes[:github].create!(title: "Tentative", external_id: "github-1", sync_collection: tentative, options: options)

    described_class.run!(output:)

    mapping = OutboxEntry.find_by(record_kind: "mapping")
    expect(mapping).to have_attributes(sync_collection_id: inferred.id, external_id: "asana-1")
    expect(mapping.payload["mapping_confidence"]).to eq("inferred")
    expect(output.string).to include("withheld_low_mappings")
  end

  it "reports a dry run without changing local provenance or the outbox" do
    item = item_classes[:omnifocus].create!(title: "Preview", external_id: "of-1", options: options)
    original_observed_at = item.last_observed_at

    described_class.run!(dry_run: true, output:)

    expect(item.reload.last_observed_at).to eq(original_observed_at)
    expect(OutboxEntry.count).to eq(0)
    expect(JSON.parse(output.string)).to include("dry_run" => true)
  end

  def backfill_item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end
end
