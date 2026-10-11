# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::ItemSnapshotEmitter do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item_class) do
    stub_const("ItemSnapshotSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end
  let(:item) do
    item_class.create!(
      title: "Buy milk",
      external_id: "of-456",
      notes: "call bob",
      options: { services: [], primary: "Omnifocus", tags: [] }
    )
  end

  before { item_class }

  it "enqueues one baseline item row marked as backfill" do
    row = described_class.emit_for_item(item, observed_at:)

    expect(row.record_kind).to eq("item")
    expect(row).to have_attributes(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      external_id: "of-456",
      observed_at:
    )
    expect(row.idempotency_key).to eq(
      "tb:v1:item:omnifocus:default:of-456:snapshot:2026-10-05T10:00:00.000000Z"
    )
    expect(row.payload).to include(
      "contract_version" => 1,
      "item_key" => "omnifocus:of-456",
      "entity_type" => "task",
      "observed_at" => "2026-10-05T10:00:00.000000Z",
      "title" => "Buy milk",
      "status" => "open",
      "is_deleted" => false,
      "source" => hash_including(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-456"
      )
    )
    expect(row.payload["provenance"]).to eq(
      "detected_by" => "backfill",
      "backfilled_at" => "2026-10-05T10:00:00.000000Z"
    )
    expect(row.payload.keys).not_to include("event_type")
  end

  it "does not write a snapshot_seen observation or advance the diff baseline" do
    expect { described_class.emit_for_item(item, observed_at:) }
      .not_to(change { OutboxEntry.where(record_kind: "observation").count })
    expect(item.reload.last_snapshot).to be_nil
  end

  it "reuses the stored row untouched for the same fact" do
    travel_to(observed_at + 1.hour) do
      first_row = described_class.emit_for_item(item, observed_at:)
      second_row = described_class.emit_for_item(item.reload, observed_at:)

      expect(second_row.id).to eq(first_row.id)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    end
  end

  it "defaults observed_at to the item's last observation for stable identity" do
    item.update_columns(last_observed_at: observed_at, updated_at: observed_at)

    row = described_class.emit_for_item(item.reload)

    expect(row.observed_at).to eq(observed_at)
    expect(row.payload["observed_at"]).to eq("2026-10-05T10:00:00.000000Z")
    expect(row.payload["provenance"]["backfilled_at"]).to eq("2026-10-05T10:00:00.000000Z")
  end

  it "keeps the payload identical across reruns of the same fact" do
    first_payload = described_class.emit_for_item(item, observed_at:).payload

    expect(described_class.emit_for_item(item.reload, observed_at:).reload.payload).to eq(first_payload)
  end

  it "omits source metadata that needs in-memory external payloads" do
    github_issue_class = stub_const("ItemSnapshotGithubIssue", Class.new(Base::SyncItem) do
      attr_accessor :github_issue

      def self.attribute_map
        {}
      end

      def provider
        "Github"
      end

      def normalized_metadata
        { number: github_issue["number"] }
      end

      def external_data
        github_issue
      end
    end)
    issue = github_issue_class.create!(title: "Fix sync", external_id: "issue-42", options: { services: [], primary: "Omnifocus", tags: [] })

    row = described_class.emit_for_item(issue, observed_at:)

    expect(row.payload["metadata"]).to eq({})
  end

  it "emits nothing for items without an external id" do
    item.update_columns(external_id: nil)

    expect(described_class.emit_for_item(item.reload, observed_at:)).to be_nil
    expect(OutboxEntry.where(record_kind: "item")).to be_empty
  end
end
