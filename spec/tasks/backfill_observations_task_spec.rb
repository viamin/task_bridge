# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_observations task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_observations")
  end

  let(:task) { Rake::Task["task_bridge:backfill_observations"] }
  let(:item_options) { options.merge(services: [], primary: "Omnifocus", tags: []) }

  before do
    task.reenable
    build_item_classes
  end

  after { ENV.delete("DRY_RUN") }

  it "seeds idempotent baseline snapshots and only publishable mapping memberships" do
    create_item(BackfillOmnifocusItem, "of-1")
    asana = create_item(BackfillAsanaItem, "asana-1")
    github = create_item(BackfillGithubItem, "gh-1")
    google_tasks = create_item(BackfillGoogleTasksItem, "gt-1")
    high_collection = mapped_collection(asana, confidence: "high", method: "source_sync_id")
    mapped_collection(github, confidence: "medium", method: "title_fallback")
    mapped_collection(google_tasks, confidence: "low", method: "manual_backfill")

    expect { task.invoke }.to output(/items_by_service/).to_stdout
    task.reenable

    first_rows = OutboxEntry.order(:id).pluck(:idempotency_key)
    task.invoke

    expect(OutboxEntry.order(:id).pluck(:idempotency_key)).to eq(first_rows)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:sync_collection_id)).to contain_exactly(
      high_collection.id,
      github.sync_collection_id
    )

    omnifocus_row = OutboxEntry.find_by!(record_kind: "item", external_id: "of-1")
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload).to include(
      "observed_at" => omnifocus_row.observed_at.utc.iso8601(6),
      "provenance" => include("detected_by" => "backfill", "initial_observation" => true)
    )
    expect(OutboxEntry.find_by!(record_kind: "mapping", external_id: "gh-1").payload)
      .to include("mapping_confidence" => "inferred")
    expect(google_tasks.reload.last_snapshot).to be_present
  end

  it "reports low-confidence mappings and incomplete items without writing in dry-run mode" do
    incomplete = BackfillAsanaItem.create!(title: "Missing external ID", options: item_options)
    incomplete.update_columns(source_service_name: nil, last_observed_at: nil)
    mapped_collection(create_item(BackfillGoogleTasksItem, "gt-low"), confidence: "low", method: "manual_backfill")
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }.to output(/item:missing_external_id.*1.*mapping:low.*1/m).to_stdout

    expect(incomplete.reload.source_service_name).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end

  private

  def build_item_classes
    stub_item_class("BackfillOmnifocusItem", "Omnifocus")
    stub_item_class("BackfillAsanaItem", "Asana")
    stub_item_class("BackfillGithubItem", "Github")
    stub_item_class("BackfillGoogleTasksItem", "GoogleTasks")
  end

  def stub_item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(item_class, external_id)
    item_class.create!(title: external_id, external_id:, options: item_options)
  end

  def mapped_collection(item, confidence:, method:)
    SyncCollection.create!(
      title: item.title,
      mapping_confidence: confidence,
      mapping_method: method,
      mapping_established_at: item.created_at,
      sync_items: [item]
    )
  end
end
