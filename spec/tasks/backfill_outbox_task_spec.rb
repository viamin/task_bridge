# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox"] }

  before do
    stub_const("BackfillOutboxTaskItem", Class.new(Base::SyncItem) do
      def self.attribute_map = {}

      def provider = "Asana"

      def external_data = {}
    end)
    task.reenable
  end

  it "prints a non-mutating dry-run summary" do
    BackfillOutboxTaskItem.create!(
      options: options.merge(service_name: "Asana"), title: "Preview", external_id: "preview-1"
    ).update_columns(source_service_name: nil, first_observed_at: nil, last_observed_at: nil)

    previous = ENV.fetch("DRY_RUN", nil)
    ENV["DRY_RUN"] = "true"
    expect { task.invoke }.to output(/"dry_run":true.*"item_snapshots":1.*"by_service":\{"asana":1\}/).to_stdout
    expect(OutboxEntry.count).to eq(0)
  ensure
    ENV["DRY_RUN"] = previous
  end
end
