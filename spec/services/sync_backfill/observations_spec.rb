# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::Observations do
  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:output) { StringIO.new }

  def item_class_for(provider)
    class_name = "Backfill#{provider}Item"
    return class_name.constantize if class_name.safe_constantize

    stub_const(class_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(provider, external_id:, collection: nil)
    item_class_for(provider).create!(
      title: "Baseline #{provider}",
      external_id:,
      sync_collection: collection,
      options: { service_name: provider, services: [], primary: "PrimaryService", tags: [] }
    )
  end

  it "creates stable baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    items = %w[Omnifocus Asana Github GoogleTasks].map.with_index do |provider, index|
      create_item(provider, external_id: "external-#{index}")
    end

    described_class.run!(output:)
    first_keys = OutboxEntry.where(record_kind: "item").order(:id).pluck(:idempotency_key)
    described_class.run!(output:)

    expect(OutboxEntry.where(record_kind: "item")).to have_attributes(count: 4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(first_keys).to eq(OutboxEntry.where(record_kind: "item").order(:id).pluck(:idempotency_key))
    expect(OutboxEntry.where(record_kind: "item").map(&:payload)).to all(
      include("provenance" => include("detected_by" => "backfill", "initial_observation" => true))
    )
    expect(items.map { |item| Outbox::SourceIdentity.for(item.reload)[:service_instance] })
      .to contain_exactly("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
  end

  it "emits confirmed mappings, withholds low-confidence mappings, and reports both" do
    confirmed = SyncCollection.create!(
      title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high", mapping_established_at: observed_at
    )
    low = SyncCollection.create!(
      title: "Review", mapping_method: "manual_backfill", mapping_confidence: "low", mapping_established_at: observed_at
    )
    create_item("Asana", external_id: "confirmed", collection: confirmed)
    create_item("Github", external_id: "review", collection: low)

    described_class.run!(output:)

    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
    expect(output.string).to include("mappings service=asana confidence=high count=1")
    expect(output.string).to include("mappings_withheld_low_confidence service=github confidence=low count=1")
  end

  it "previews skipped incomplete records without mutating data" do
    item = create_item("GoogleTasks", external_id: nil)
    item.update_columns(source_service_name: nil, last_observed_at: nil)

    described_class.run!(dry_run: true, output:)

    expect(item.reload.source_service_name).to be_nil
    expect(OutboxEntry.count).to eq(0)
    expect(output.string).to include("items_skipped_incomplete service=google_tasks confidence=none count=1")
  end
end
