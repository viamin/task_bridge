# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-06T10:00:00Z") }
  let(:backfilled_at) { Time.zone.parse("2026-10-12T10:00:00Z") }
  let(:providers) do
    {
      "OmniFocus" => "Omnifocus",
      "Asana" => "Asana:work",
      "Github" => "Github:repo-1",
      "GoogleTasks" => "GoogleTasks:list-1"
    }
  end

  before do
    providers.each do |constant_name, service_name|
      provider = provider_for(constant_name)
      stub_const("Backfill#{constant_name}Item", Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        define_singleton_method(:attribute_map) { {} }

        define_method(:external_data) { {} }
      end)
      create_item(constant_name, service_name)
    end
  end

  it "seeds idempotent baseline snapshots for representative services" do
    described_class.run!(backfilled_at:)
    first_keys = OutboxEntry.order(:id).pluck(:idempotency_key)

    described_class.run!(backfilled_at:)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.order(:id).pluck(:idempotency_key)).to eq(first_keys)
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_type)).to contain_exactly(
      "omnifocus", "asana", "github", "google_tasks"
    )
    expect(OutboxEntry.find_by(service_type: "omnifocus").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(service_type: "asana").payload).to include(
      "backfilled_at" => "2026-10-12T10:00:00.000000Z",
      "provenance" => { "detected_by" => "backfill" }
    )
    expect(Base::SyncItem.find_each.all? { |item| item.last_snapshot.present? }).to be(true)
  end

  it "reports low-confidence mappings without writing in dry-run mode" do
    summary = described_class.run!(dry_run: true, backfilled_at:)

    expect(summary).to include(
      items_by_service: {
        "asana" => 1,
        "github" => 1,
        "google_tasks" => 1,
        "omnifocus" => 1
      },
      mappings_by_confidence: { "high" => 1, "low" => 1, "medium" => 2 }
    )
    expect(summary[:skipped]).to include("withheld_low_confidence" => 1)
    expect(OutboxEntry.all).to be_empty
  end

  private

  def create_item(constant_name, service_name)
    confidence = { "OmniFocus" => "high", "Asana" => "medium", "Github" => "medium", "GoogleTasks" => "low" }
    collection = SyncCollection.create!(
      title: "#{constant_name} task",
      mapping_method: confidence.fetch(constant_name) == "high" ? "source_sync_id" : "title_fallback",
      mapping_confidence: confidence.fetch(constant_name),
      mapping_last_observed_at: observed_at
    )
    "Backfill#{constant_name}Item".constantize.create!(
      title: "#{constant_name} task",
      external_id: "#{constant_name.downcase}-1",
      last_modified: observed_at,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "OmniFocus", tags: [], pretend: false }
    )
  end

  def provider_for(constant_name)
    {
      "OmniFocus" => "Omnifocus",
      "Asana" => "Asana",
      "Github" => "Github",
      "GoogleTasks" => "Google Tasks"
    }.fetch(constant_name)
  end
end
