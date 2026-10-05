# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::ActivityEmitter do
  let(:options) do
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end
  let(:github_issue) do
    {
      "id" => 123,
      "number" => 5,
      "title" => "Ship activity feed",
      "state" => "open",
      "body" => "private source body",
      "html_url" => "https://github.com/org/repo/issues/5",
      "repository_url" => "https://api.github.com/repos/org/repo",
      "updated_at" => "2026-10-05T12:00:00Z",
      "labels" => []
    }
  end
  let(:item) do
    Github::Issue.new(github_issue:, options:, external_id: "123", source_service_name: "github").tap(&:refresh_from_external!)
  end
  let(:occurred_at) { "2026-10-05T11:00:00Z" }
  let(:since) { Time.iso8601("2026-10-05T10:00:00Z") }

  it "emits idempotent, redacted comment activity" do
    events = [{
      "id" => 456,
      "event" => "commented",
      "created_at" => occurred_at,
      "actor" => { "login" => "octocat" },
      "body" => "this must never leave the adapter"
    }]

    2.times { described_class.emit_for(item, events:, since:) }

    rows = OutboxEntry.where(record_kind: "observation").where.not(event_type: "snapshot_seen")
    expect(rows.count).to eq(1)
    row = rows.first
    expect(row.idempotency_key).to end_with(":activity:456")
    expect(row.payload.fetch("activity")).to include(
      "type" => "comment_added", "source_event_id" => "456", "actor" => "octocat"
    )
    expect(row.payload.to_json).not_to include("this must never leave the adapter")
  end

  it "publishes meaningful issue state changes but ignores events before the cursor" do
    events = [
      { "id" => 1, "event" => "labeled", "created_at" => "2026-10-05T09:59:59Z" },
      { "id" => 2, "event" => "closed", "created_at" => occurred_at },
      { "id" => 3, "event" => "subscribed", "created_at" => occurred_at }
    ]

    described_class.emit_for(item, events:, since:)

    activities = OutboxEntry.where(record_kind: "observation").where.not(event_type: "snapshot_seen")
                            .map { |entry| entry.payload.fetch("activity") }
    expect(activities).to contain_exactly(include("type" => "closed", "source_event_id" => "2"))
  end

  it "publishes review metadata without its body" do
    review = {
      "id" => 789,
      "activity_type" => "reviewed",
      "submitted_at" => occurred_at,
      "state" => "APPROVED",
      "body" => "private review text"
    }

    described_class.emit_for(item, events: [review], since:)

    activity = OutboxEntry.where(record_kind: "observation").where.not(event_type: "snapshot_seen")
                          .sole.payload.fetch("activity")
    expect(activity).to include("type" => "reviewed", "details" => { "review_state" => "APPROVED" })
  end

  it "derives an idempotent opened activity from the issue response" do
    opened_item = Github::Issue.new(
      github_issue: github_issue.merge("created_at" => occurred_at, "user" => { "login" => "octocat" }),
      options:, external_id: "123", source_service_name: "github"
    ).tap(&:refresh_from_external!)

    2.times { described_class.emit_for(opened_item, events: [], since:) }

    row = OutboxEntry.where(record_kind: "observation").where.not(event_type: "snapshot_seen").sole
    expect(row.idempotency_key).to end_with(":activity:123-opened")
    expect(row.payload.fetch("activity")).to include(
      "type" => "opened", "source_event_id" => "123-opened", "actor" => "octocat"
    )
  end

  it "does not publish an opening that predates the cursor" do
    stale_item = Github::Issue.new(
      github_issue: github_issue.merge("created_at" => "2026-10-05T09:59:59Z", "user" => { "login" => "octocat" }),
      options:, external_id: "123", source_service_name: "github"
    ).tap(&:refresh_from_external!)

    described_class.emit_for(stale_item, events: [], since:)

    expect(OutboxEntry.where(record_kind: "observation").where.not(event_type: "snapshot_seen")).to be_empty
  end
end
