# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  before do
    stub_item_class("BackfillOmniFocusItem", "Omnifocus")
    stub_item_class("BackfillAsanaItem", "Asana")
    stub_item_class("BackfillGithubItem", "Github")
    stub_item_class("BackfillGoogleTasksItem", "GoogleTasks")
  end

  it "seeds idempotent baseline snapshots and only publishable mapping memberships" do
    omnifocus = create_item(BackfillOmniFocusItem, "of-1")
    asana = create_item(BackfillAsanaItem, "asana-1")
    github = create_item(BackfillGithubItem, "github-1")
    google_tasks = create_item(BackfillGoogleTasksItem, "gt-1")
    add_to_collection("Confirmed", "high", omnifocus, asana)
    add_to_collection("Inferred", "medium", github)
    add_to_collection("Review", "low", google_tasks)

    preview = described_class.run!(dry_run: true)
    expect(preview).to include(
      dry_run: true,
      snapshots: include(enqueued: 4, by_service: { "omnifocus" => 1, "asana" => 1, "github" => 1,
                                                    "google_tasks" => 1 }),
      mappings: include(enqueued: 3, by_service: { "omnifocus" => 1, "asana" => 1, "github" => 1,
                                                   "google_tasks" => 1 },
                        by_confidence: { "high" => 2, "medium" => 1, "low" => 1 },
                        withheld_low_confidence: 1)
    )
    expect(OutboxEntry.count).to eq(0)

    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").map(&:service_instance))
      .to contain_exactly("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
    expect(OutboxEntry.where(record_kind: "item").first.payload.dig("provenance", "baseline")).to be(true)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).not_to include("gt-1")

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
  end

  def stub_item_class(name, provider)
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

  def create_item(item_class, external_id)
    item_class.create!(title: external_id, external_id:, options:)
  end

  def add_to_collection(title, confidence, *items)
    collection = SyncCollection.create!(title:, mapping_method: "source_sync_id", mapping_confidence: confidence)
    items.each { |item| item.update!(sync_collection: collection) }
  end
end
