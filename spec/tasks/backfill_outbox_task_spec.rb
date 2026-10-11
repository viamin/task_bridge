# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox task", :full_options do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox"] }
  let(:backfilled_at) { Time.zone.parse("2026-10-11T12:00:00Z") }

  before do
    task.reenable
    ENV.delete("DRY_RUN")
    define_item_class("BackfillAsanaItem", "Asana")
    define_item_class("BackfillOmniFocusItem", "Omnifocus")
    define_item_class("BackfillGithubItem", "Github")
    define_item_class("BackfillGoogleTasksItem", "GoogleTasks")
  end

  after { ENV.delete("DRY_RUN") }

  it "creates idempotent baseline snapshots for the supported existing services" do
    items = [
      create_item(BackfillAsanaItem, "asana-1"),
      create_item(BackfillOmniFocusItem, "omnifocus-1"),
      create_item(BackfillGithubItem, "github-1"),
      create_item(BackfillGoogleTasksItem, "google-tasks-1")
    ]

    travel_to(backfilled_at) { task.invoke }
    task.reenable
    travel_to(backfilled_at + 1.hour) { task.invoke }

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.count).to eq(4)
    expect(rows.map(&:service_type)).to contain_exactly("asana", "omnifocus", "github", "google_tasks")
    expect(rows.map(&:service_instance)).to contain_exactly(
      "asana:default", "omnifocus:default", "github:default", "google_tasks:default"
    )
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(rows.map { |row| row.payload.dig("provenance", "baseline") }).to all(eq(true))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
  end

  it "withholds low-confidence mappings and reports them without writing in dry run" do
    collection = SyncCollection.create!(title: "Needs review")
    create_item(BackfillAsanaItem, "asana-2", collection:)

    ENV["DRY_RUN"] = "1"
    expect { task.invoke }.to output(/"withheld".*"tentative".*"asana"/).to_stdout

    expect(OutboxEntry.count).to eq(0)
    expect(collection.reload.mapping_method).to be_nil
  end

  it "backfills confirmed ID-derived memberships with baseline provenance" do
    collection = SyncCollection.create!(title: "Linked task")
    create_item(BackfillAsanaItem, "asana-3", collection:, notes: "omnifocus_id: omnifocus-3")
    create_item(BackfillOmniFocusItem, "omnifocus-3", collection:, notes: "asana_id: asana-3")

    travel_to(backfilled_at) { task.invoke }

    rows = OutboxEntry.where(record_kind: "mapping")
    expect(rows.map(&:external_id)).to contain_exactly("asana-3", "omnifocus-3")
    expect(rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
  end

  def define_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }
      define_method(:provider) { provider }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(item_class, external_id, collection: nil, notes: "safe notes")
    item_class.create!(
      title: "Current task",
      external_id:,
      notes:,
      sync_collection: collection,
      options: options.merge(service_name: item_class.new.provider)
    )
  end
end
