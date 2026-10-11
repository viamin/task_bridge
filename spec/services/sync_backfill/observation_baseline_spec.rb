# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::ObservationBaseline, :full_options do
  let(:item_classes) do
    {
      omnifocus: build_item_class("BaselineOmniFocusItem", "OmniFocus"),
      asana: build_item_class("BaselineAsanaItem", "Asana"),
      github: build_item_class("BaselineGithubItem", "Github"),
      google_tasks: build_item_class("BaselineGoogleTasksItem", "Google Tasks")
    }
  end

  def build_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(type, external_id:, collection: nil, service_name: nil)
    item_classes.fetch(type).create!(
      title: "#{type} task",
      external_id:,
      sync_collection: collection,
      options: options.merge(service_name: service_name || type.to_s)
    )
  end

  it "seeds idempotent baseline snapshots for representative providers without observations" do
    items = [
      create_item(:omnifocus, external_id: "of-1", service_name: "OmniFocus"),
      create_item(:asana, external_id: "asana-1", service_name: "Asana:work"),
      create_item(:github, external_id: "gh-1", service_name: "Github:repo-1"),
      create_item(:google_tasks, external_id: "gt-1", service_name: "Google Tasks")
    ]

    summary = described_class.run!

    expect(summary[:items_by_service]).to eq(
      "asana" => 1, "github" => 1, "google_tasks" => 1, "omni_focus" => 1
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty

    omnifocus_row = OutboxEntry.find_by(external_id: "of-1")
    expect(omnifocus_row.service_instance).to eq("omni_focus:default")
    expect(omnifocus_row.payload).to include(
      "observed_at" => omnifocus_row.observed_at.utc.iso8601(6),
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => omnifocus_row.observed_at.utc.iso8601(6))
    )

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
    expect(items.map { |item| item.reload.last_observed_at }).to all(be_present)
  end

  it "queues high and medium confidence memberships while reporting low confidence memberships as withheld" do
    high = SyncCollection.create!(title: "high")
    medium = SyncCollection.create!(title: "medium")
    low = SyncCollection.create!(title: "low")
    high_item = create_item(:asana, external_id: "high-1", collection: high, service_name: "Asana:work")
    medium_item = create_item(:github, external_id: "medium-1", collection: medium, service_name: "Github:repo")
    low_item = create_item(:omnifocus, external_id: "low-1", collection: low, service_name: "OmniFocus")
    high.update!(mapping_method: "source_sync_id", mapping_confidence: "high")
    medium.update!(mapping_method: "title_fallback", mapping_confidence: "medium")
    low.update!(mapping_method: "manual_backfill", mapping_confidence: "low")

    summary = described_class.run!

    expect(summary[:mappings_by_confidence]).to eq("high" => 1, "medium" => 1)
    expect(summary[:withheld_mappings_by_confidence]).to eq("low" => 1)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly(high_item.external_id, medium_item.external_id)
    expect(OutboxEntry.find_by(external_id: medium_item.external_id, record_kind: "mapping").payload["mapping_confidence"])
      .to eq("inferred")
    expect(OutboxEntry.where(external_id: low_item.external_id, record_kind: "mapping")).to be_empty
  end

  it "reports incomplete legacy records without mutating them during a dry run" do
    incomplete = create_item(:asana, external_id: "incomplete", service_name: "Asana:work")
    incomplete.update_columns(external_id: nil, source_external_id: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    expect(summary[:skipped_items_by_service]).to eq("asana" => 1)
    expect(OutboxEntry.count).to eq(0)
    expect(incomplete.reload.last_observed_at).to be_nil
  end
end
