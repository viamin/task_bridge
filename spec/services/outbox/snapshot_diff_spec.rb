# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SnapshotDiff do
  let(:base_snapshot) do
    {
      version: 1,
      item_key: "test_service:obs-1",
      entity_type: "task",
      source: { service_type: "test_service", service_instance: "test_service", external_id: "obs-1" },
      sync_collection_id: nil,
      observed_at: Time.zone.parse("2026-10-05T10:00:00Z"),
      title: "Buy milk",
      display_title: "Buy milk",
      status: "open",
      completed: false,
      completed_at: nil,
      is_deleted: false,
      due_at: Time.zone.parse("2026-10-06T17:00:00Z"),
      due_date: nil,
      start_at: nil,
      start_date: nil,
      source_created_at: Time.zone.parse("2026-10-01T09:00:00Z"),
      source_updated_at: Time.zone.parse("2026-10-05T09:00:00Z"),
      flagged: false,
      priority: nil,
      estimated_minutes: nil,
      project: "Errands",
      tags: %w[Home Errands],
      assignee: nil,
      notes_digest: "abc123",
      parent_item_id: nil,
      sub_item_count: 0,
      sub_item_keys: [],
      metadata: { "section" => "Today", "progress" => 0.5 }
    }
  end

  def transition(field)
    described_class.transitions(base_snapshot, yield(base_snapshot.deep_dup))
                   .find { |t| t["field"] == field }
  end

  it "returns no transitions for identical snapshots" do
    expect(described_class.transitions(base_snapshot, base_snapshot.deep_dup)).to eq([])
  end

  it "returns no transitions when either snapshot is blank" do
    expect(described_class.transitions(nil, base_snapshot)).to eq([])
    expect(described_class.transitions(base_snapshot, nil)).to eq([])
  end

  it "detects a title change" do
    expect(transition("title") { |s| s.merge(title: "Buy oat milk") })
      .to eq({ "field" => "title", "from" => "Buy milk", "to" => "Buy oat milk" })
  end

  it "detects completion as status and completed_at transitions" do
    completed_at = Time.zone.parse("2026-10-05T10:05:00Z")
    new_snapshot = base_snapshot.deep_merge(
      status: "completed",
      completed: true,
      completed_at:
    )

    transitions = described_class.transitions(base_snapshot, new_snapshot)

    expect(transitions).to contain_exactly(
      { "field" => "status", "from" => "open", "to" => "completed" },
      { "field" => "completed_at", "from" => nil, "to" => completed_at.utc.iso8601(6) }
    )
  end

  it "detects reopening as the inverse status transition" do
    reopen_snapshot = base_snapshot.deep_merge(status: "completed", completed: true)
    reopened = reopen_snapshot.deep_merge(status: "open", completed: false, completed_at: nil)

    expect(described_class.transitions(reopen_snapshot, reopened))
      .to contain_exactly({ "field" => "status", "from" => "completed", "to" => "open" })
  end

  it "compares timestamps across JSON round-trips without false transitions" do
    round_tripped = base_snapshot.deep_stringify_keys

    expect(described_class.transitions(round_tripped, base_snapshot)).to eq([])
  end

  it "reports due date changes with normalized ISO timestamps" do
    new_due = Time.zone.parse("2026-10-08T12:00:00Z")

    expect(transition("due_at") { |s| s.merge(due_at: new_due) })
      .to eq({ "field" => "due_at", "from" => "2026-10-06T17:00:00.000000Z", "to" => "2026-10-08T12:00:00.000000Z" })
  end

  it "reports tag membership changes order-insensitively" do
    expect(transition("tags") { |s| s.merge(tags: %w[Errands Home Grocery]) })
      .to eq({ "field" => "tags", "from" => %w[Errands Home], "to" => %w[Errands Grocery Home] })
  end

  it "reports changes to containment metadata fields" do
    expect(transition("metadata.section") { |s| s.deep_merge(metadata: { "section" => "Upcoming" }) })
      .to eq({ "field" => "metadata.section", "from" => "Today", "to" => "Upcoming" })
  end

  it "reports flag, priority, project, notes digest, and parent changes" do
    aggregate_failures do
      expect(transition("flagged") { |s| s.merge(flagged: true) }).to be_present
      expect(transition("priority") { |s| s.merge(priority: "high") }).to be_present
      expect(transition("project") { |s| s.merge(project: "Home") }).to be_present
      expect(transition("notes_digest") { |s| s.merge(notes_digest: "def456") }).to be_present
      expect(transition("parent_item_id") { |s| s.merge(parent_item_id: 7) }).to be_present
      expect(transition("sub_item_count") { |s| s.merge(sub_item_count: 2) }).to be_present
    end
  end

  it "ignores volatile, derived, provenance-only, and unobserved metadata fields" do
    new_snapshot = base_snapshot.deep_merge(
      observed_at: Time.zone.parse("2026-10-05T11:00:00Z"),
      sync_collection_id: 84,
      source_updated_at: Time.zone.parse("2026-10-05T10:59:00Z"),
      source_created_at: Time.zone.parse("2026-09-01T09:00:00Z"),
      metadata: { "section" => "Today", "progress" => 0.9 }
    )

    expect(described_class.transitions(base_snapshot, new_snapshot)).to eq([])
  end

  it "ignores derived display and lifecycle mirror fields" do
    new_snapshot = base_snapshot.deep_merge(display_title: "buy milk", completed: true, status: "open")

    expect(described_class.transitions(base_snapshot, new_snapshot)).to eq([])
  end
end
