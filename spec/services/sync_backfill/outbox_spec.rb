# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-12T09:00:00Z") }

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }
      define_method(:provider) { provider }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(klass, service_name:, external_id:, collection:, notes: nil)
    klass.create!(
      title: "Release checklist",
      external_id:,
      notes:,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "Asana", tags: [] }
    )
  end

  it "backfills idempotent baseline snapshots for each supported service without observations" do
    collection = SyncCollection.create!(title: "Release checklist")
    omnifocus = item_class("BackfillOmniFocusItem", "Omnifocus")
    asana = item_class("BackfillAsanaItem", "Asana")
    github = item_class("BackfillGithubItem", "Github")
    google_tasks = item_class("BackfillGoogleTasksItem", "GoogleTasks")
    items = [
      create_item(omnifocus, service_name: "Omnifocus", external_id: "of-1", collection:, notes: "asana_id: asana-1"),
      create_item(asana, service_name: "Asana", external_id: "asana-1", collection:, notes: "omnifocus_id: of-1"),
      create_item(github, service_name: "Github", external_id: "gh-1", collection:),
      create_item(google_tasks, service_name: "GoogleTasks", external_id: "gt-1", collection:)
    ]
    items.each do |item|
      item.update_columns(source_service_name: nil, source_service_instance: nil, last_observed_at: nil,
                          first_observed_at: nil, source_metadata: nil)
    end

    travel_to(observed_at) { described_class.run! }
    first_keys = OutboxEntry.pluck(:idempotency_key)
    travel_to(observed_at + 1.day) { described_class.run! }

    expect(OutboxEntry.where(record_kind: "item")).to have_attributes(count: 4)
    expect(OutboxEntry.where(record_kind: "mapping")).to have_attributes(count: 4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.pluck(:idempotency_key)).to match_array(first_keys)
    expect(OutboxEntry.where(record_kind: "item").map(&:payload)).to all(include(
                                                                           "provenance" => include("detected_by" => "backfill")
                                                                         ))
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to match_array(
      %w[omnifocus:default asana:default github:default google_tasks:default]
    )
  end

  it "reports and withholds low-confidence mappings during a dry run" do
    collection = SyncCollection.create!(title: "Uncertain")
    github = item_class("LowConfidenceGithubItem", "Github")
    create_item(github, service_name: "Github", external_id: "gh-1", collection:)

    summary = described_class.run!(dry_run: true)

    expect(summary).to include([:items, "Github", nil] => 1, [:skipped_mappings, "Github", "low_confidence"] => 1)
    expect(OutboxEntry.all).to be_empty
  end
end
