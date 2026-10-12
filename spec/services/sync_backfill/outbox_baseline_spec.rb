# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-12T10:00:00Z") }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  let(:asana_class) { sync_item_class("BackfillAsanaItem", "Asana") }
  let(:github_class) { sync_item_class("BackfillGithubItem", "Github") }
  let(:omnifocus_class) { sync_item_class("BackfillOmniFocusItem", "Omnifocus") }
  let(:google_tasks_class) { sync_item_class("BackfillGoogleTasksItem", "GoogleTasks") }

  before do
    asana_class
    github_class
    omnifocus_class
    google_tasks_class
  end

  it "writes idempotent baseline item snapshots and only publishable mappings" do
    confirmed = SyncCollection.create!(title: "Release", mapping_method: "source_sync_id", mapping_confidence: "high")
    tentative = SyncCollection.create!(title: "Personal", mapping_method: "title_fallback", mapping_confidence: "low")
    create_item(asana_class, "asana-1", confirmed, "Asana:work")
    create_item(github_class, "github-1", confirmed, "Github:repo")
    create_item(omnifocus_class, "omni-1", tentative, "Omnifocus")
    create_item(google_tasks_class, "google-1", tentative, "GoogleTasks")

    travel_to(observed_at) { described_class.run!(backfilled_at: observed_at) }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("asana-1", "github-1")

    omnifocus_row = OutboxEntry.find_by!(record_kind: "item", external_id: "omni-1")
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload).to include(
      "observed_at" => omnifocus_row.observed_at.iso8601(6),
      "provenance" => include("detected_by" => "backfill", "baseline" => true, "backfilled_at" => observed_at.iso8601(6))
    )

    expect do
      described_class.run!(backfilled_at: observed_at + 1.day)
    end.not_to change(OutboxEntry, :count)
  end

  it "reports a dry run without writing local provenance or outbox rows" do
    collection = SyncCollection.create!(title: "Personal", mapping_method: "title_fallback", mapping_confidence: "low")
    item = create_item(omnifocus_class, "omni-1", collection, "Omnifocus")
    item.update_columns(source_service_name: nil, source_service_instance: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true, backfilled_at: observed_at)

    expect(summary).to include(
      items: include(services: include("omnifocus" => 1)),
      skipped: include(mappings_low_confidence: 1)
    )
    expect(item.reload.source_service_name).to be_nil
    expect(OutboxEntry.all).to be_empty
  end

  def sync_item_class(name, provider_name)
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

  def create_item(item_class, external_id, collection, service_name)
    item_class.create!(
      title: external_id,
      external_id:,
      sync_collection: collection,
      options: options.merge(service_name:)
    )
  end
end
