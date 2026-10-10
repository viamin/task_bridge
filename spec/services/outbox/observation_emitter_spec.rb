# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::ObservationEmitter do
  include ActiveSupport::Testing::TimeHelpers

  let(:item_class) do
    stub_const("ObservationSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "TestService"
      end

      def external_data
        @sync_item
      end
    end)
  end
  let(:options) do
    {
      quiet: true,
      pretend: false,
      services: [],
      primary: "Omnifocus",
      tags: [],
      sync_started_at: "2026-10-05T10:00:00.000000Z"
    }
  end
  let(:first_observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item) do
    item_class.new(
      sync_item: { "id" => "obs-1", "title" => "Buy milk", "completed" => false },
      options:,
      external_id: "obs-1"
    )
  end

  def refresh_with(external_attributes, at:)
    travel_to(at) do
      item.instance_variable_set(:@sync_item, { "id" => "obs-1" }.merge(external_attributes))
      item.refresh_from_external!
    end
  end

  def observation_rows(field: nil)
    scope = OutboxEntry.where(record_kind: "observation")
    return scope.to_a if field.nil?

    scope.select { |entry| entry.payload.dig("change", "field") == field }
  end

  before { item_class }

  describe "first observation" do
    it "emits a single snapshot_seen row and stores the diff baseline" do
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at)

      rows = observation_rows
      expect(rows.length).to eq(1)

      row = rows.first
      expect(row.event_type).to eq("snapshot_seen")
      expect(row.external_id).to eq("obs-1")
      expect(row.service_type).to eq("test_service")
      # Single-instance services carry the permanent `:default` instance
      # token (#222) so backfilled and live rows share identities.
      expect(row.service_instance).to eq("test_service:default")
      expect(row.observed_at).to eq(first_observed_at)
      expect(row.payload["event_type"]).to eq("snapshot_seen")
      expect(row.payload["item_key"]).to eq("test_service:obs-1")
      expect(row.payload["source"]).to include(
        "service_type" => "test_service",
        "service_instance" => "test_service:default",
        "external_id" => "obs-1"
      )
      expect(row.payload["change"]).to be_nil
      expect(row.payload["snapshot"]["title"]).to eq("Buy milk")
      expect(row.payload["provenance"]).to include(
        "detected_by" => "source_refresh",
        "sync_run_id" => "sync-run-2026-10-05T10:00:00.000000Z"
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:obs:test_service:default:obs-1:snapshot_seen:2026-10-05T10:00:00.000000Z"
      )
      expect(item.reload.last_snapshot).to include("title" => "Buy milk")
    end

    it "does not re-emit discovery when the item refreshes unchanged" do
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at)
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at + 1.hour)

      expect(observation_rows.length).to eq(1)
      expect(observation_rows.first.event_type).to eq("snapshot_seen")
    end

    it "skips the baseline UPDATE when no observed fields changed" do
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at)
      baseline_after_discovery = item.reload.last_snapshot

      expect(item).not_to receive(:update_column)
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at + 1.hour)

      expect(observation_rows.length).to eq(1)
      expect(observation_rows.first.event_type).to eq("snapshot_seen")
      expect(item.reload.last_snapshot).to eq(baseline_after_discovery)
    end
  end

  describe "source changes" do
    before do
      refresh_with(
        { "title" => "Buy milk", "completed" => false, "due_at" => Time.zone.parse("2026-10-06T17:00:00Z") },
        at: first_observed_at
      )
    end

    it "emits distinct observations for completion and later reopening" do
      completed_at = Time.zone.parse("2026-10-05T10:30:00Z")
      refresh_with({ "title" => "Buy milk", "completed" => true, "completed_at" => completed_at,
                     "due_at" => Time.zone.parse("2026-10-06T17:00:00Z") },
                   at: first_observed_at + 1.hour)
      refresh_with({ "title" => "Buy milk", "completed" => false, "completed_at" => nil,
                     "due_at" => Time.zone.parse("2026-10-06T17:00:00Z") },
                   at: first_observed_at + 2.hours)

      status_rows = observation_rows(field: "status")
      expect(status_rows.map { |row| row.payload["change"] }).to contain_exactly(
        { "field" => "status", "from" => "open", "to" => "completed" },
        { "field" => "status", "from" => "completed", "to" => "open" }
      )
      expect(status_rows.map(&:idempotency_key).uniq.length).to eq(2)
    end

    it "makes repeated due date movement reconstructable from the published rows" do
      refresh_with({ "title" => "Buy milk", "completed" => false,
                     "due_at" => Time.zone.parse("2026-10-08T12:00:00Z") },
                   at: first_observed_at + 1.hour)
      refresh_with({ "title" => "Buy milk", "completed" => false,
                     "due_at" => Time.zone.parse("2026-10-09T09:00:00Z") },
                   at: first_observed_at + 2.hours)

      due_rows = observation_rows(field: "due_at")
      expect(due_rows.length).to eq(2)
      expect(due_rows.first.payload["change"]).to eq(
        { "field" => "due_at", "from" => "2026-10-06T17:00:00.000000Z", "to" => "2026-10-08T12:00:00.000000Z" }
      )
      expect(due_rows.second.payload["change"]).to eq(
        { "field" => "due_at", "from" => "2026-10-08T12:00:00.000000Z", "to" => "2026-10-09T09:00:00.000000Z" }
      )
      expect(due_rows.second.payload["change"]["from"]).to eq(due_rows.first.payload["change"]["to"])
    end

    it "emits one row per transition with distinct sequenced idempotency keys" do
      refresh_with(
        { "title" => "Buy oat milk", "completed" => true,
          "completed_at" => Time.zone.parse("2026-10-05T11:00:00Z"),
          "due_at" => Time.zone.parse("2026-10-06T17:00:00Z"),
          "flagged" => true },
        at: first_observed_at + 1.hour
      )

      rows = observation_rows.select { |entry| entry.payload["change"] }
      fields = rows.map { |row| row.payload.dig("change", "field") }
      expect(fields).to contain_exactly("title", "status", "completed_at", "flagged")
      expect(rows.map(&:idempotency_key).uniq.length).to eq(rows.length)
      expect(rows.map { |row| row.idempotency_key.split(":").last }).to contain_exactly("1", "2", "3", "4")
    end

    it "carries sync_compare provenance and completion context on change rows" do
      refresh_with({ "title" => "Buy oat milk", "completed" => false }, at: first_observed_at + 1.hour)

      row = observation_rows(field: "title").first
      expect(row.payload["provenance"]["detected_by"]).to eq("sync_compare")
      expect(row.payload["snapshot"]).to be_nil
    end
  end

  describe "outbox write failures" do
    before do
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at)
    end

    it "does not abort the refresh when enqueue fails, and retains the baseline for re-detection" do
      allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

      expect do
        refresh_with({ "title" => "Buy oat milk", "completed" => false }, at: first_observed_at + 1.hour)
      end.not_to raise_error
      expect(item.reload.last_snapshot).to include("title" => "Buy milk")

      allow(OutboxEntry).to receive(:enqueue).and_call_original
      refresh_with({ "title" => "Buy oat milk", "completed" => false }, at: first_observed_at + 2.hours)

      expect(observation_rows(field: "title").length).to eq(1)
      expect(item.reload.last_snapshot).to include("title" => "Buy oat milk")
    end

    it "reports the dropped observation" do
      allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

      expect do
        refresh_with({ "title" => "Buy oat milk", "completed" => false }, at: first_observed_at + 1.hour)
      end.to output(/dropping observation for test_service:obs-1/).to_stderr
    end
  end

  describe "guard clauses" do
    it "emits nothing and keeps the baseline untouched in pretend mode" do
      refresh_with({ "title" => "Buy milk", "completed" => false }, at: first_observed_at)
      item.options = options.merge(pretend: true)

      refresh_with({ "title" => "Pretend change", "completed" => false }, at: first_observed_at + 1.hour)

      expect(observation_rows.length).to eq(1)
      expect(item.reload.last_snapshot).to include("title" => "Buy milk")
    end

    it "emits nothing for items without an external id" do
      item.external_id = nil

      expect(described_class.emit_for_item(item, previous_snapshot: nil)).to eq([])
      expect(OutboxEntry.count).to eq(0)
    end
  end
end
