# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::ItemSnapshots do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  def create_item(klass, service_name:, external_id:, title: "Buy milk")
    klass.create!(
      options: { service_name:, services: [], primary: "Omnifocus", tags: [] },
      title:,
      external_id:
    )
  end

  describe ".run!" do
    it "enqueues one baseline item snapshot per representative service, marked as a backfill baseline" do
      travel_to(observed_at) do
        create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-1")
        create_item(Asana::Task, service_name: "Asana:work", external_id: "asana-1")
        create_item(Github::Issue, service_name: "Github:repo-1", external_id: "issue-1")
        create_item(GoogleTasks::Task, service_name: "GoogleTasks", external_id: "gt-1")
      end

      summary = described_class.run!

      expect(summary).to eq(
        enqueued: 4,
        skipped_incomplete: 0,
        by_service: { "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1 }
      )

      of_entry = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
      expect(of_entry.service_instance).to eq("omnifocus:default")
      expect(of_entry.observed_at).to eq(observed_at)
      expect(of_entry.payload).to include("title" => "Buy milk", "is_deleted" => false, "entity_type" => "task")
      expect(of_entry.payload["provenance"]).to include("detected_by" => "backfill")
      expect(of_entry.payload["provenance"]).to have_key("backfilled_at")

      expect(OutboxEntry.find_by(record_kind: "item", external_id: "asana-1").service_instance).to eq("asana:work")
      expect(OutboxEntry.find_by(record_kind: "item", external_id: "issue-1").service_instance).to eq("github:repo-1")
      expect(OutboxEntry.find_by(record_kind: "item", external_id: "gt-1").service_instance).to eq("google_tasks:default")
    end

    it "skips items that have not been through identity backfill yet" do
      item = create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-2")
      item.update_columns(source_service_name: nil, source_external_id: nil, last_observed_at: nil)

      summary = described_class.run!

      expect(summary).to eq(enqueued: 0, skipped_incomplete: 1, by_service: {})
      expect(OutboxEntry.where(record_kind: "item")).to be_empty
    end

    it "is idempotent across repeated runs" do
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-3")

      first_summary = described_class.run!
      second_summary = described_class.run!

      expect(first_summary[:enqueued]).to eq(1)
      expect(second_summary[:enqueued]).to eq(1)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    end

    it "reports counts without writing outbox rows in dry-run mode" do
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-4")

      summary = described_class.run!(dry_run: true)

      expect(summary).to eq(enqueued: 1, skipped_incomplete: 0, by_service: { "omnifocus" => 1 })
      expect(OutboxEntry.where(record_kind: "item")).to be_empty
    end
  end
end
