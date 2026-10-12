# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::Runner, :full_options do
  let(:now) { Time.zone.parse("2026-10-12T12:00:00.000000Z") }
  let(:logger) { instance_double(StructuredLogger, debug: nil) }

  before do
    Thread.current[:global_options] = options.merge(pretend: false)
  end

  def stub_item_class(const_name:, provider:)
    stub_const(const_name, Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      define_method(:provider) { provider }

      def external_data
        {}
      end
    end)
  end

  describe ".run!" do
    it "emits both baseline item snapshots and mapping rows on a live run" do
      item_class = stub_item_class(const_name: "RunnerBackfillItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      member = item_class.create!(
        title: "Release checklist",
        external_id: "gh-runner",
        sync_collection: collection,
        last_modified: Time.zone.parse("2026-10-08T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-08T00:00:00Z"),
        options: options.merge(service_name: "Github:repo-1")
      )
      item_class.create!(
        title: "Standalone",
        external_id: "gh-standalone",
        last_modified: Time.zone.parse("2026-10-08T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-08T00:00:00Z"),
        options: options.merge(service_name: "Github:repo-1")
      )

      io = StringIO.new
      original = $stdout
      $stdout = io
      begin
        summary = described_class.run!(dry_run: false, now:, logger:)
      ensure
        $stdout = original
      end

      expect(summary[:items_emitted]).to eq(2)
      expect(summary[:mappings_emitted]).to eq(1)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(2)
      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
      expect(io.string).to include("Backfilled")
      expect(io.string).to include("github: 2")
      expect(io.string).to include("high: 1")
      expect(member.reload.last_snapshot).to be_present
    end

    it "renders the same summary in dry-run mode without writing rows" do
      item_class = stub_item_class(const_name: "RunnerDryRunItem", provider: "Omnifocus")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "of-dry",
        sync_collection: collection,
        last_modified: Time.zone.parse("2026-10-09T00:00:00Z"),
        options: options.merge(service_name: "Omnifocus")
      )

      io = StringIO.new
      original = $stdout
      $stdout = io
      begin
        summary = described_class.run!(dry_run: true, now:, logger:)
      ensure
        $stdout = original
      end

      expect(summary[:items_emitted]).to eq(1)
      expect(summary[:mappings_emitted]).to eq(1)
      expect(OutboxEntry.count).to eq(0)
      expect(io.string).to include("Would backfill")
      expect(io.string).to include("Dry run only")
      expect(io.string).to include("omnifocus: 1")
    end

    it "distinguishes live and dry-run summaries so operators can preview safely" do
      item_class = stub_item_class(const_name: "RunnerLiveVsDryItem", provider: "Omnifocus")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "of-distinct",
        sync_collection: collection,
        last_modified: Time.zone.parse("2026-10-10T00:00:00Z"),
        options: options.merge(service_name: "Omnifocus")
      )

      dry_io = StringIO.new
      live_io = StringIO.new

      capture(dry_io) { described_class.run!(dry_run: true, now:, logger:) }
      expect(OutboxEntry.count).to eq(0)
      capture(live_io) { described_class.run!(dry_run: false, now:, logger:) }
      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)

      expect(dry_io.string).not_to eq(live_io.string)
      expect(dry_io.string).to include("Would backfill")
      expect(live_io.string).to include("Backfilled")
    end

    it "summarizes counts by service, by confidence, and withheld low-confidence memberships" do
      item_class = stub_item_class(const_name: "RunnerMultiServiceItem", provider: "Github")
      high_collection = SyncCollection.create!(
        title: "High",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      medium_collection = SyncCollection.create!(
        title: "Medium",
        mapping_method: "title_fallback",
        mapping_confidence: "medium"
      )
      low_collection = SyncCollection.create!(
        title: "Low",
        mapping_method: "manual_backfill",
        mapping_confidence: "low"
      )
      asana_item_class = stub_item_class(const_name: "RunnerAsanaItem", provider: "Asana")
      omnifocus_item_class = stub_item_class(const_name: "RunnerOmnifocusItem", provider: "Omnifocus")
      gtask_item_class = stub_item_class(const_name: "RunnerGoogleTaskItem", provider: "GoogleTasks")

      item_class.create!(
        title: "GH high",
        external_id: "gh-high",
        sync_collection: high_collection,
        last_modified: Time.zone.parse("2026-10-11T00:00:00Z"),
        options: options.merge(service_name: "Github:repo-1")
      )
      item_class.create!(
        title: "GH medium",
        external_id: "gh-medium",
        sync_collection: medium_collection,
        last_modified: Time.zone.parse("2026-10-11T00:00:00Z"),
        options: options.merge(service_name: "Github:repo-1")
      )
      item_class.create!(
        title: "GH low",
        external_id: "gh-low",
        sync_collection: low_collection,
        last_modified: Time.zone.parse("2026-10-11T00:00:00Z"),
        options: options.merge(service_name: "Github:repo-1")
      )
      asana_item_class.create!(
        title: "Asana",
        external_id: "asana-1",
        last_modified: Time.zone.parse("2026-10-11T00:00:00Z"),
        options: options.merge(service_name: "Asana:work")
      )
      omnifocus_item_class.create!(
        title: "OmniFocus",
        external_id: "of-1",
        last_modified: Time.zone.parse("2026-10-11T00:00:00Z"),
        options: options.merge(service_name: "Omnifocus")
      )
      gtask_item_class.create!(
        title: "GTask",
        external_id: "gt-1",
        last_modified: Time.zone.parse("2026-10-11T00:00:00Z"),
        options: options.merge(service_name: "GoogleTasks")
      )

      io = StringIO.new
      capture(io) { described_class.run!(dry_run: true, now:, logger:) }
      output = io.string

      expect(output).to include("github: 3")
      expect(output).to include("asana: 1")
      expect(output).to include("omnifocus: 1")
      expect(output).to include("google_tasks: 1")
      expect(output).to include("high: 1")
      expect(output).to include("medium: 1")
      expect(output).to include("low (withheld): 1")
      expect(output).to include("Withheld 1 low-confidence memberships")
    end
  end

  def capture(io)
    original = $stdout
    $stdout = io
    yield
  ensure
    $stdout = original
  end
end
