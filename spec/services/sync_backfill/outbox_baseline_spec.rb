# frozen_string_literal: true

require "rails_helper"

# Baseline backfill coverage (#222): existing sync data becomes baseline
# current state in the outbox — one `item` snapshot per existing sync item
# and mapping rows only for confirmed/inferred memberships — without
# pretending to be historical change events (no observation or sync_run
# rows). Representative records cover OmniFocus, Asana, GitHub, and
# Google Tasks.
RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:created_at) { Time.zone.parse("2026-10-09T09:00:00Z") }
  let(:run_at) { Time.zone.parse("2026-10-10T12:00:00Z") }

  # Freeze before the let! blocks create rows (let! behaves as a before
  # hook in declaration order) so created/updated timestamps are stable
  # across every example regardless of wall-clock time.
  before { travel_to(created_at) }
  after { travel_back }

  # Sync-id linked pair (OmniFocus <-> Asana:work): backfills to a
  # source_sync_id/high/confirmed mapping.
  let!(:confirmed_collection) { SyncCollection.create!(title: "Buy milk") }
  let!(:omnifocus_task) do
    Omnifocus::Task.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-1",
      notes: "asana_work_id: asana-1",
      url: "omnifocus:///task/of-1",
      sync_collection: confirmed_collection
    )
  end
  let!(:asana_task) do
    Asana::Task.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-1",
      notes: "omnifocus_id: of-1",
      url: "https://app.asana.com/0/0/asana-1",
      sync_collection: confirmed_collection
    )
  end

  # Title-derived pair (OmniFocus <-> Google Tasks): backfills to a
  # title_fallback/medium/inferred mapping.
  let!(:inferred_collection) { SyncCollection.create!(title: "Release checklist") }
  let!(:omnifocus_checklist_task) do
    Omnifocus::Task.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Release checklist",
      external_id: "of-2",
      sync_collection: inferred_collection
    )
  end
  let!(:google_task) do
    GoogleTasks::Task.create!(
      options: options.merge(service_name: "GoogleTasks"),
      title: "Release checklist",
      external_id: "gt-1",
      sync_collection: inferred_collection
    )
  end

  # Single-member GitHub collection: a bare persisted issue carries no
  # transient payload, so no evidence links it to anything and the
  # provenance backfill records manual_backfill/low, which the baseline
  # withholds from publication but keeps identifiable in the summary.
  let!(:low_confidence_collection) { SyncCollection.create!(title: "Deploy backlog") }
  let!(:github_issue) do
    Github::Issue.create!(
      options: options.merge(service_name: "Github:repo-1"),
      title: "Deploy backlog",
      external_id: "gh-1",
      sync_collection: low_confidence_collection
    )
  end

  # Incomplete legacy row: no external identity, so it cannot be published.
  let!(:incomplete_item) do
    Omnifocus::Task.create!(options: options.merge(service_name: "Omnifocus"), title: "No external id")
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  it "enqueues one baseline item snapshot per existing item across services" do
    summary = described_class.run!(now: run_at)

    expect(item_rows.count).to eq(5)
    expect(summary[:items]).to include(enqueued: 5, skipped: 1, dropped: 0)
    expect(summary[:items][:by_service]).to eq(
      "omnifocus" => 2, "asana" => 1, "github" => 1, "google_tasks" => 1
    )

    asana_row = item_rows.find { |row| row.external_id == "asana-1" }
    expect(asana_row).to have_attributes(
      service_type: "asana",
      service_instance: "asana:work",
      sync_collection_id: confirmed_collection.id,
      observed_at: created_at
    )
    expect(asana_row.idempotency_key).to eq(
      "tb:v1:item:asana:work:asana-1:snapshot:#{created_at.utc.iso8601(6)}"
    )
    expect(asana_row.payload).to include(
      "contract_version" => 1,
      "entity_type" => "task",
      "item_key" => "asana_work:asana-1",
      "title" => "Buy milk",
      "status" => "open",
      "is_deleted" => false
    )
    expect(asana_row.payload["source"]).to include(
      "service_type" => "asana",
      "service_instance" => "asana:work",
      "external_id" => "asana-1",
      "source_url" => "https://app.asana.com/0/0/asana-1"
    )
    expect(asana_row.payload["provenance"]).to include(
      "detected_by" => "backfill",
      "backfilled_at" => run_at.utc.iso8601(6),
      "baseline" => true,
      "first_observed_at" => created_at.utc.iso8601(6)
    )
    expect(asana_row.payload["sync_collection"]).to include(
      "sync_collection_id" => confirmed_collection.id,
      "title" => "Buy milk",
      "membership_role" => "member"
    )

    omnifocus_row = item_rows.find { |row| row.external_id == "of-1" }
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload["source"]).to include("source_url" => "omnifocus:///task/of-1")

    github_row = item_rows.find { |row| row.external_id == "gh-1" }
    expect(github_row.service_instance).to eq("github:repo-1")
    # Bare persisted rows carry no transient external payload, so the
    # source-specific metadata section is omitted rather than crashing.
    expect(github_row.payload["metadata"]).to eq({})
  end

  it "writes no observation or sync_run rows" do
    described_class.run!(now: run_at)

    expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
  end

  it "backfills mapping provenance and publishes only confirmed and inferred memberships" do
    summary = described_class.run!(now: run_at)

    expect(low_confidence_collection.reload).to have_attributes(
      mapping_method: "manual_backfill", mapping_confidence: "low"
    )
    expect(confirmed_collection.reload).to have_attributes(
      mapping_method: "source_sync_id", mapping_confidence: "high"
    )
    expect(inferred_collection.reload).to have_attributes(
      mapping_method: "title_fallback", mapping_confidence: "medium"
    )

    expect(mapping_rows.map(&:external_id)).to contain_exactly("of-1", "asana-1", "of-2", "gt-1")
    confirmed_row = mapping_rows.find { |row| row.external_id == "of-1" }
    expect(confirmed_row.payload).to include(
      "mapping_confidence" => "confirmed",
      "mapping_source" => "sync_id_note"
    )
    expect(confirmed_row.payload["provenance"]).to include(
      "detected_by" => "backfill",
      "backfilled_at" => run_at.utc.iso8601(6)
    )
    inferred_row = mapping_rows.find { |row| row.external_id == "gt-1" }
    expect(inferred_row.payload).to include(
      "mapping_confidence" => "inferred",
      "mapping_source" => "title_match"
    )

    expect(mapping_rows.map(&:external_id)).not_to include("gh-1")
    expect(summary[:mappings]).to include(enqueued: 4, withheld: 1, skipped: 0, dropped: 0)
    expect(summary[:mappings][:by_confidence]).to eq(
      "confirmed" => 2, "inferred" => 2, "tentative" => 1
    )
  end

  it "is idempotent across reruns" do
    described_class.run!(now: run_at)
    payloads_before = OutboxEntry.all.index_by(&:idempotency_key).transform_values(&:payload)

    described_class.run!(now: run_at + 1.hour)

    rows_after = OutboxEntry.all.index_by(&:idempotency_key)
    expect(rows_after.keys).to contain_exactly(*payloads_before.keys)
    rows_after.each do |key, row|
      expect(row.payload).to eq(payloads_before[key])
    end
  end

  it "previews counts in dry-run mode without writing anything" do
    summary = described_class.run!(dry_run: true, now: run_at)

    expect(OutboxEntry.count).to eq(0)
    expect(summary[:dry_run]).to be(true)
    expect(summary[:items]).to include(enqueued: 5, skipped: 1)
    expect(summary[:items][:by_service]).to eq(
      "omnifocus" => 2, "asana" => 1, "github" => 1, "google_tasks" => 1
    )
    expect(summary[:mappings]).to include(enqueued: 4, withheld: 1)
    expect(summary[:mappings][:by_confidence]).to include("tentative" => 1)
    # The provenance backfill writes, so a dry run must not invoke it.
    expect(low_confidence_collection.reload.mapping_method).to be_nil
  end
end
