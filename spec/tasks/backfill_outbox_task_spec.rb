# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox"] }

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }
      define_method(:provider) { provider }
      define_method(:external_data) { {} }
    end)
  end

  before do
    task.reenable
    %w[Omnifocus Asana Github GoogleTasks].each { |provider| item_class("Baseline#{provider}Item", provider) }
  end

  it "creates idempotent baseline snapshots for supported services and withholds low mappings" do
    high = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    low = SyncCollection.create!(title: "Review", mapping_method: "manual_backfill", mapping_confidence: "low")
    {
      "BaselineOmnifocusItem" => ["of-1", high],
      "BaselineAsanaItem" => ["asana-1", high],
      "BaselineGithubItem" => ["gh-1", low],
      "BaselineGoogleTasksItem" => ["gt-1", low]
    }.each do |class_name, (external_id, collection)|
      class_name.constantize.create!(title: external_id, external_id:, sync_collection: collection)
    end

    expect { task.invoke }.to change { OutboxEntry.count }.by(6)
    task.reenable
    expect { task.invoke }.not_to(change { OutboxEntry.count })

    snapshots = OutboxEntry.where(record_kind: "item")
    expect(snapshots.count).to eq(4)
    expect(snapshots.pluck(:service_instance)).to include("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
    expect(snapshots.map { |row| row.payload["provenance"] }).to all(include("detected_by" => "backfill", "baseline" => true))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("of-1", "asana-1")
  end

  it "reports a non-mutating dry run" do
    BaselineOmnifocusItem.create!(title: "No ID")
    ENV["DRY_RUN"] = "true"

    expect { task.invoke }.to output(/"dry_run":true/).to_stdout
    expect(OutboxEntry.all).to be_empty
  ensure
    ENV.delete("DRY_RUN")
  end
end
