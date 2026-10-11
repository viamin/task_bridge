# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineSnapshots do
  let(:omnifocus_item) do
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1",
                            options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] })
  end
  let(:asana_item) do
    Asana::Task.create!(title: "Ship release", external_id: "asana-1",
                        options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] })
  end
  let(:github_item) do
    Github::Issue.create!(title: "Fix bug", external_id: "issue-1",
                          options: { service_name: "Github:repo-1", services: [], primary: "Omnifocus", tags: [] })
  end
  let(:google_tasks_item) do
    GoogleTasks::Task.create!(title: "Call dentist", external_id: "gtask-1",
                              options: { service_name: "GoogleTasks", services: [], primary: "Omnifocus", tags: [] })
  end
  let(:incomplete_item) do
    item = Omnifocus::Task.create!(title: "Legacy row", external_id: "of-2",
                                   options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] })
    item.update_columns(source_service_name: nil, source_service_type: nil, source_service_instance: nil)
    item
  end

  before { [omnifocus_item, asana_item, github_item, google_tasks_item, incomplete_item] }

  describe "#summary" do
    it "counts eligible items by service and lists incomplete ones without writing anything" do
      summary = described_class.new.summary

      expect(summary[:by_service]).to eq("omnifocus" => 1, "asana_work" => 1, "github_repo_1" => 1, "google_tasks" => 1)
      expect(summary[:enqueued]).to eq(4)
      expect(summary[:skipped]).to contain_exactly({ id: incomplete_item.id, reason: "missing_source_identity" })
      expect(OutboxEntry.count).to eq(0)
    end
  end

  describe "#run!" do
    it "enqueues one baseline item row per representative service" do
      described_class.new.run!

      rows = OutboxEntry.where(record_kind: "item")
      expect(rows.pluck(:external_id)).to contain_exactly("of-1", "asana-1", "issue-1", "gtask-1")
      expect(rows.pluck(:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:work", "github:repo-1", "google_tasks:default"
      )
      expect(rows.map { |row| row.payload["provenance"] }).to all(include("detected_by" => "backfill"))
    end

    it "is idempotent across repeated runs" do
      described_class.new.run!

      expect { described_class.new.run! }.not_to(change { OutboxEntry.where(record_kind: "item").count })
    end
  end
end
