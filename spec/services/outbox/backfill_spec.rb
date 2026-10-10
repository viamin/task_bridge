# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  let(:mapping_observed_at) { Time.zone.parse("2026-10-09T08:00:00Z") }

  # Representative existing rows across the required services: a
  # single-instance service (OmniFocus), an instanced service (Asana:work),
  # and provider/task services (GitHub, Google Tasks).
  let!(:omnifocus_task) do
    Omnifocus::Task.create!(
      title: "Buy milk",
      external_id: "of-77",
      url: "omnifocus:///task/of-77",
      last_modified: Time.zone.parse("2026-10-01T09:00:00Z"),
      options: options.merge(service_name: "Omnifocus")
    )
  end
  let!(:asana_task) do
    Asana::Task.create!(
      title: "Buy milk",
      external_id: "1201",
      options: options.merge(service_name: "Asana:work")
    )
  end
  let!(:github_issue) do
    Github::Issue.create!(
      title: "Release checklist",
      external_id: "42",
      github_issue: {
        "number" => 42,
        "state" => "open",
        "repository_url" => "https://api.github.com/repos/viamin/task_bridge",
        "user" => { "login" => "viamin" }
      },
      options: options.merge(service_name: "Github")
    )
  end
  let!(:google_task) do
    GoogleTasks::Task.create!(
      title: "Buy milk",
      external_id: "gt-9",
      options: options.merge(service_name: "GoogleTasks")
    )
  end

  def create_collection(title:, method:, confidence:, members:)
    SyncCollection.create!(
      title:,
      mapping_method: method,
      mapping_confidence: confidence,
      mapping_last_observed_at: mapping_observed_at
    ).tap { |collection| members.each { |member| member.update!(sync_collection: collection) } }
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe ".run!" do
    it "enqueues one baseline item snapshot per existing sync item for each service" do
      summary = described_class.run!

      expect(summary[:dry_run]).to be(false)
      expect(item_rows.count).to eq(4)
      expect(item_rows.map(&:external_id)).to contain_exactly("of-77", "1201", "42", "gt-9")

      row = item_rows.find { |entry| entry.external_id == "of-77" }
      expect(row).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        observed_at: omnifocus_task.last_observed_at,
        sync_collection_id: nil
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-77:snapshot:#{omnifocus_task.last_observed_at.utc.iso8601(6)}"
      )

      expect(item_rows.find { |entry| entry.external_id == "1201" })
        .to have_attributes(service_type: "asana", service_instance: "asana:work")
      expect(item_rows.find { |entry| entry.external_id == "42" })
        .to have_attributes(service_type: "github", service_instance: "github:default")
      expect(item_rows.find { |entry| entry.external_id == "gt-9" })
        .to have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")
    end

    it "marks item rows as baseline facts rather than historical change events" do
      described_class.run!

      row = item_rows.find { |entry| entry.external_id == "of-77" }
      expect(row.payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-77",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-77",
        "source_url" => "omnifocus:///task/of-77"
      )
      expect(row.payload["provenance"]).to include("detected_by" => "backfill")
      expect(row.payload["provenance"]["backfilled_at"]).to be_present
      expect(row.payload).to have_key("source_metadata")
      expect(row.payload).not_to have_key("metadata")
      expect(row.payload).not_to have_key("version")
      # No observation rows come from the backfill: baseline state is a
      # current-state snapshot, not a snapshot_seen change event (#222).
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end

    it "keeps backfill output limited to the local outbox and provenance fields" do
      # The backfill must never mutate external source systems: titles,
      # notes, external ids, and source URLs of existing rows stay put.
      original_attributes = Base::SyncItem.order(:id).map { |item| item.slice(:id, :title, :notes, :external_id, :url) }

      described_class.run!

      expect(Base::SyncItem.order(:id).map { |item| item.slice(:id, :title, :notes, :external_id, :url) })
        .to eq(original_attributes)
      expect(OutboxEntry.pluck(:record_kind).uniq).to contain_exactly("item")
    end

    it "captures missing identity and provenance fields before publishing" do
      github_issue.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, source_updated_at: nil,
        first_observed_at: nil, last_observed_at: nil, source_metadata: nil
      )

      described_class.run!

      expect(github_issue.reload.source_service_name).to eq("Github")
      expect(github_issue.source_service_instance).to be_nil
      row = item_rows.find { |entry| entry.external_id == "42" }
      expect(row.service_instance).to eq("github:default")
      expect(row.observed_at).to eq(github_issue.last_observed_at)
    end

    it "skips records without external identity and reports them by service" do
      incomplete = Github::Issue.create!(title: "No id yet", options: options.merge(service_name: "Github"))

      summary = described_class.run!

      expect(item_rows.map(&:external_id)).not_to include(incomplete.external_id)
      expect(summary[:items]).to include(total: 5, enqueued: 4, skipped: 1)
      expect(summary[:items][:by_service]).to include(
        "omnifocus" => { enqueued: 1, skipped: 0 },
        "asana" => { enqueued: 1, skipped: 0 },
        "github" => { enqueued: 1, skipped: 1 },
        "google_tasks" => { enqueued: 1, skipped: 0 }
      )
    end

    it "is safe to run multiple times" do
      travel_to(Time.zone.parse("2026-10-10T12:00:00Z")) { described_class.run! }
      keys_after_first_run = OutboxEntry.order(:idempotency_key).pluck(:idempotency_key)
      row = item_rows.find { |entry| entry.external_id == "of-77" }
      backfilled_at = row.payload["provenance"]["backfilled_at"]

      summary = nil
      travel_to(Time.zone.parse("2026-10-11T09:30:00Z")) { summary = described_class.run! }

      expect(OutboxEntry.order(:idempotency_key).pluck(:idempotency_key)).to eq(keys_after_first_run)
      expect(summary[:items][:enqueued]).to eq(4)
      expect(summary[:mappings][:memberships]).to eq(0)
      # The stored payload is immutable across reruns: the baseline marker
      # keeps the original run's timestamp.
      expect(row.reload.payload["provenance"]["backfilled_at"]).to eq(backfilled_at)
    end

    it "enqueues mapping memberships for confirmed and inferred collections using stored timestamps" do
      high = create_collection(title: "Synced via ids", method: "source_sync_id", confidence: "high",
                               members: [omnifocus_task, asana_task])
      medium = create_collection(title: "Matched by title", method: "title_fallback", confidence: "medium",
                                 members: [github_issue])

      described_class.run!

      stamp = mapping_observed_at.utc.iso8601(6)
      keys = mapping_rows.map(&:idempotency_key)
      expect(keys).to contain_exactly(
        "tb:v1:map:sync_collection:#{high.id}:membership:omnifocus:default:of-77:#{stamp}",
        "tb:v1:map:sync_collection:#{high.id}:membership:asana:work:1201:#{stamp}",
        "tb:v1:map:sync_collection:#{medium.id}:membership:github:default:42:#{stamp}"
      )
      confidence_by_collection = mapping_rows.index_by(&:sync_collection_id)
      expect(confidence_by_collection[high.id].payload["mapping_confidence"]).to eq("confirmed")
      expect(confidence_by_collection[medium.id].payload["mapping_confidence"]).to eq("inferred")
    end

    it "withholds low-confidence memberships from publication while keeping them identifiable" do
      high = create_collection(title: "Synced via ids", method: "source_sync_id", confidence: "high",
                               members: [google_task])
      low = create_collection(title: "Assumed pair", method: "manual_backfill", confidence: "low",
                              members: [omnifocus_task, asana_task])
      medium = create_collection(title: "Matched by title", method: "title_fallback", confidence: "medium",
                                 members: [github_issue])

      summary = described_class.run!

      expect(mapping_rows.map(&:sync_collection_id)).to contain_exactly(medium.id, high.id)
      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: low.id)).to be_empty
      expect(summary[:mappings]).to include(memberships: 4, enqueued: 2, withheld: 2)
      expect(summary[:mappings][:by_confidence]).to include(
        "high" => { enqueued: 1, withheld: 0 },
        "medium" => { enqueued: 1, withheld: 0 },
        "low" => { enqueued: 0, withheld: 2 }
      )
    end

    it "counts memberships without recorded confidence as withheld" do
      # A method-bearing collection missing its confidence keeps it (the
      # provenance backfill only fills fully-unmapped collections), so the
      # backfill withholds it under an explicit unknown bucket.
      unknown = SyncCollection.create!(title: "Legacy pair", mapping_method: "source_sync_id")
      omnifocus_task.update!(sync_collection: unknown)
      asana_task.update!(sync_collection: unknown)

      summary = described_class.run!

      expect(mapping_rows).to be_empty
      expect(summary[:mappings][:by_confidence]).to include(
        "unknown" => { enqueued: 0, withheld: 2 }
      )
    end
  end

  describe ".dry_run" do
    it "reports the same counts without writing anything" do
      create_collection(title: "Assumed pair", method: "manual_backfill", confidence: "low",
                        members: [omnifocus_task, asana_task])
      create_collection(title: "Synced via ids", method: "source_sync_id", confidence: "high",
                        members: [github_issue, google_task])
      omnifocus_task.update_columns(last_observed_at: nil, first_observed_at: nil)

      summary = described_class.dry_run

      expect(summary[:dry_run]).to be(true)
      expect(OutboxEntry.count).to eq(0)
      expect(summary[:items]).to include(total: 4, enqueued: 4, skipped: 0)
      expect(summary[:mappings]).to include(memberships: 4, enqueued: 2, withheld: 2)
      expect(summary[:mappings][:by_confidence]).to include(
        "high" => { enqueued: 2, withheld: 0 },
        "low" => { enqueued: 0, withheld: 2 }
      )
      # Dry run never backfills provenance either: nothing is written.
      expect(omnifocus_task.reload.last_observed_at).to be_nil
    end
  end

  describe ".format_summary" do
    it "renders counts by service and confidence with the run mode" do
      summary = {
        dry_run: true,
        items: { total: 3, enqueued: 2, skipped: 1,
                 by_service: { "omnifocus" => { enqueued: 2, skipped: 1 } } },
        mappings: { memberships: 2, enqueued: 1, withheld: 1,
                    by_confidence: { "low" => { enqueued: 0, withheld: 1 }, "high" => { enqueued: 1, withheld: 0 } } }
      }

      output = described_class.format_summary(summary)

      expect(output).to eq(
        "Outbox backfill dry run (nothing was written):\n  " \
        "item snapshots: 2 enqueued, 1 skipped/incomplete\n    " \
        "omnifocus: 2 enqueued, 1 skipped/incomplete\n  " \
        "mapping memberships: 1 enqueued, 1 withheld\n    " \
        "high: 1 enqueued, 0 withheld\n    " \
        "low: 0 enqueued, 1 withheld"
      )
    end
  end
end
