# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  let(:observed_at) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:service_options) { options.merge(services: [], primary: "Omnifocus", tags: []) }

  before do
    stub_const("OmnifocusBackfillItem", backfill_item_class("Omnifocus"))
    stub_const("AsanaBackfillItem", backfill_item_class("Asana"))
    stub_const("GithubBackfillItem", backfill_item_class("Github"))
    stub_const("GoogleTasksBackfillItem", backfill_item_class("GoogleTasks"))
  end

  it "seeds one baseline snapshot per representative service without observations" do
    items = [
      OmnifocusBackfillItem.create!(title: "Inbox", external_id: "of-1", options: service_options),
      AsanaBackfillItem.create!(title: "Work", external_id: "asana-1", options: service_options.merge(service_name: "Asana:work")),
      GithubBackfillItem.create!(title: "Issue", external_id: "gh-1", options: service_options),
      GoogleTasksBackfillItem.create!(title: "List", external_id: "gt-1", options: service_options)
    ]
    items.each { |item| item.update_columns(first_observed_at: observed_at, last_observed_at: observed_at) }

    summary = described_class.run!

    expect(summary).to include(items: 4, mappings: 0, withheld_mappings: 0)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.find_by!(external_id: "of-1")).to have_attributes(service_instance: "omnifocus:default", observed_at: observed_at)
    expect(OutboxEntry.find_by!(external_id: "gt-1").payload).to include(
      "baseline" => true,
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => "2026-10-12T12:00:00.000000Z")
    )
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
  end

  it "is idempotent and withholds low-confidence mappings" do
    collection = SyncCollection.create!(title: "Shared")
    confirmed = AsanaBackfillItem.create!(
      title: "Shared", external_id: "asana-1", notes: "omnifocus_id: of-1",
      sync_collection: collection, options: service_options
    )
    OmnifocusBackfillItem.create!(title: "Shared", external_id: "of-1", notes: "asana_id: asana-1",
                                  sync_collection: collection, options: service_options)
    low_collection = SyncCollection.create!(title: "Uncertain")
    GithubBackfillItem.create!(title: "Uncertain", external_id: "gh-1", sync_collection: low_collection,
                               options: service_options)

    first_summary = described_class.run!
    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("asana-1", "of-1")
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:idempotency_key).uniq.length).to eq(2)
    expect(first_summary).to include(withheld_mappings: 1)
    expect(confirmed.reload.sync_collection.mapping_confidence).to eq("high")
  end

  it "reports planned work without mutating local records in dry-run mode" do
    item = GoogleTasksBackfillItem.create!(title: "Unobserved", external_id: "gt-1", options: service_options)
    item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil,
                        source_external_id: nil, first_observed_at: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(items: 1)
    expect(item.reload.source_service_name).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end

  def backfill_item_class(provider_name)
    Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }
      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end
  end
end
