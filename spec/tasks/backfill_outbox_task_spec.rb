# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox task", :full_options do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox"] }
  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }

  before do
    task.reenable
    stub_service_items
  end

  after { ENV.delete("DRY_RUN") }

  it "seeds idempotent baseline snapshots for existing provider records" do
    items = [
      create_item(BackfillOmniFocusItem, "of-1"),
      create_item(BackfillAsanaItem, "asana-1", service_name: "Asana:work"),
      create_item(BackfillGithubItem, "gh-1", service_name: "Github:repo"),
      create_item(BackfillGoogleTasksItem, "gt-1")
    ]

    travel_to(observed_at) { task.invoke }
    task.reenable
    travel_to(observed_at + 1.hour) { task.invoke }

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.pluck(:external_id)).to eq(%w[asana-1 gh-1 gt-1 of-1])
    expect(rows.pluck(:idempotency_key).uniq.length).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(rows.find_by(external_id: "of-1").service_instance).to eq("omnifocus:default")
    expect(rows.find_by(external_id: "asana-1").service_instance).to eq("asana:work")
    expect(rows).to all(have_attributes(status: "pending"))
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
  end

  it "publishes only high and medium mapping memberships and reports held low mappings" do
    high = SyncCollection.create!(title: "high", mapping_method: "source_sync_id", mapping_confidence: "high")
    medium = SyncCollection.create!(title: "medium", mapping_method: "title_fallback", mapping_confidence: "medium")
    low = SyncCollection.create!(title: "low", mapping_method: "title_fallback", mapping_confidence: "low")
    create_item(BackfillAsanaItem, "high-1", collection: high)
    create_item(BackfillGithubItem, "medium-1", collection: medium)
    create_item(BackfillOmniFocusItem, "low-1", collection: low)

    expect { task.invoke }.to output(/mappings\.low\.low_confidence":1/).to_stdout

    rows = OutboxEntry.where(record_kind: "mapping")
    expect(rows.pluck(:external_id)).to contain_exactly("high-1", "medium-1")
    expect(rows.find_by(external_id: "high-1").payload["mapping_confidence"]).to eq("confirmed")
    expect(rows.find_by(external_id: "medium-1").payload["mapping_confidence"]).to eq("inferred")
  end

  it "reports dry-run counts without writing provenance, snapshots, or mappings" do
    item = create_item(BackfillOmniFocusItem, "of-dry")
    item.update_columns(source_service_name: nil, last_observed_at: nil)
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }.to output(/"dry_run":true/).to_stdout

    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.source_service_name).to be_nil
    expect(item.last_snapshot).to be_nil
  end

  def stub_service_items
    stub_item("BackfillOmniFocusItem", "Omnifocus")
    stub_item("BackfillAsanaItem", "Asana")
    stub_item("BackfillGithubItem", "Github")
    stub_item("BackfillGoogleTasksItem", "Google Tasks")
  end

  def stub_item(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(klass, external_id, service_name: nil, collection: nil)
    klass.create!(
      title: external_id,
      external_id:,
      last_modified: observed_at - 1.day,
      sync_collection: collection,
      options: options.merge(service_name: service_name || klass.new.provider)
    )
  end
end
