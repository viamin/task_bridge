# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineObservations, :full_options do
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
    it "emits one baseline item snapshot per existing sync item" do
      item_class = stub_item_class(const_name: "BaselineItemOmnifocus", provider: "Omnifocus")
      item_class.create!(
        title: "Buy milk",
        external_id: "of-77",
        last_modified: Time.zone.parse("2026-10-01T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-01T00:00:00Z"),
        options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] }
      )

      counts = described_class.run!(now:)

      expect(counts[:items_seen]).to eq(1)
      expect(counts[:items_emitted]).to eq(1)
      row = OutboxEntry.find_by!(record_kind: "item")
      expect(row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-77:snapshot:2026-10-01T00:00:00.000000Z"
      )
      expect(row.service_instance).to eq("omnifocus:default")
      expect(row.observed_at).to eq(Time.zone.parse("2026-10-01T00:00:00Z"))
      expect(row.payload).to include(
        "contract_version" => 1,
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(row.payload["provenance"]).to include("detected_by" => "backfill")
      expect(row.payload["provenance"]["backfilled_at"]).to eq(now.utc.iso8601(6))
    end

    it "is idempotent across repeated runs" do
      item_class = stub_item_class(const_name: "BaselineItemAsana", provider: "Asana")
      item_class.create!(
        title: "Buy milk",
        external_id: "asana-123",
        last_modified: Time.zone.parse("2026-10-02T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-02T00:00:00Z"),
        options: { service_name: "Asana:work", services: [], primary: "Asana", tags: [] }
      )

      described_class.run!(now:)
      first_id = OutboxEntry.find_by(record_kind: "item").id
      described_class.run!(now:)

      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
      expect(OutboxEntry.find_by(record_kind: "item").id).to eq(first_id)
    end

    it "advances the diff baseline so future live observation emission diffs against it" do
      item_class = stub_item_class(const_name: "BaselineItemDiff", provider: "Github")
      item = item_class.create!(
        title: "Buy milk",
        external_id: "gh-1",
        last_modified: Time.zone.parse("2026-10-03T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-03T00:00:00Z"),
        options: { service_name: "Github:repo-1", services: [], primary: "Github", tags: [] }
      )

      described_class.run!(now:)

      expect(item.reload.last_snapshot).to include(
        "title" => "Buy milk",
        "version" => Base::SnapshotSerializer::VERSION
      )
    end

    it "marks rows carrying an explicit instance instead of falling back to :default" do
      item_class = stub_item_class(const_name: "BaselineItemGithubInstance", provider: "Github")
      item_class.create!(
        title: "Buy milk",
        external_id: "gh-1",
        last_modified: Time.zone.parse("2026-10-04T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-04T00:00:00Z"),
        options: { service_name: "Github:repo-1", services: [], primary: "Github", tags: [] }
      )

      described_class.run!(now:)

      row = OutboxEntry.find_by(record_kind: "item")
      expect(row.service_instance).to eq("github:repo-1")
      expect(row.idempotency_key).to eq(
        "tb:v1:item:github:repo-1:gh-1:snapshot:2026-10-04T00:00:00.000000Z"
      )
    end

    it "skips items missing an external_id" do
      item_class = stub_item_class(const_name: "BaselineItemSkipped", provider: "GoogleTasks")
      item_class.create!(
        title: "Buy milk",
        external_id: nil,
        last_modified: Time.zone.parse("2026-10-05T00:00:00Z"),
        options: { service_name: "GoogleTasks", services: [], primary: "GoogleTasks", tags: [] }
      )

      counts = described_class.run!(now:)

      expect(counts[:items_skipped]).to eq(1)
      expect(OutboxEntry.count).to eq(0)
    end

    it "carries common current-state fields from the normalized snapshot" do
      item_class = stub_item_class(const_name: "BaselineItemSnapshotFields", provider: "Omnifocus")
      parent_class = stub_item_class(const_name: "BaselineItemSnapshotFieldsParent", provider: "Omnifocus")
      collection = SyncCollection.create!(title: "Buy milk")
      parent = parent_class.create!(
        title: "Parent",
        external_id: "of-parent",
        options: options.merge(service_name: "Omnifocus")
      )
      item_class.create!(
        title: "Buy milk",
        external_id: "of-100",
        notes: "Buy 2% organic",
        due_at: Time.zone.parse("2026-10-20T17:00:00Z"),
        completed_at: Time.zone.parse("2026-10-05T10:00:00Z"),
        completed: true,
        flagged: true,
        source_created_at: Time.zone.parse("2026-09-15T00:00:00Z"),
        source_updated_at: Time.zone.parse("2026-10-04T00:00:00Z"),
        last_modified: Time.zone.parse("2026-10-04T00:00:00Z"),
        last_observed_at: Time.zone.parse("2026-10-04T00:00:00Z"),
        sync_collection: collection,
        parent_item_id: parent.id,
        options: options.merge(service_name: "Omnifocus", tags: ["Groceries"])
      )

      described_class.run!(now:)

      payload = OutboxEntry.find_by(record_kind: "item", external_id: "of-100").payload
      expect(payload["title"]).to eq("Buy milk")
      expect(payload["status"]).to eq("completed")
      expect(payload["completed"]).to be true
      expect(payload["completed_at"]).to be_present
      expect(payload["due_at"]).to be_present
      # Tags carry the global default tags plus the service name; the
      # backfill serializes tags via the normalized snapshot, which
      # mirrors the live publication path.
      expect(payload["tags"]).to include("Omnifocus")
      expect(payload["source"]["service_instance"]).to eq("omnifocus:default")
      expect(payload["sync_collection"]).to include(
        "sync_collection_id" => collection.id,
        "title" => "Buy milk"
      )
      expect(payload["parent"]).to include(
        "external_id" => "of-parent",
        "item_key" => parent.item_key
      )
    end

    it "isolates an outbox write failure and continues with the next item" do
      first_class = stub_item_class(const_name: "BaselineItemIsolatedFirst", provider: "Omnifocus")
      second_class = stub_item_class(const_name: "BaselineItemIsolatedSecond", provider: "Omnifocus")
      first_class.create!(
        title: "First",
        external_id: "of-fail",
        last_modified: Time.zone.parse("2026-10-06T00:00:00Z"),
        options: options.merge(service_name: "Omnifocus")
      )
      second_class.create!(
        title: "Second",
        external_id: "of-ok",
        last_modified: Time.zone.parse("2026-10-06T00:00:00Z"),
        options: options.merge(service_name: "Omnifocus")
      )
      attempt = 0
      allow(OutboxEntry).to receive(:enqueue).and_wrap_original do |original, **kwargs|
        attempt += 1
        raise ActiveRecord::StatementInvalid, "simulated outbox failure" if kwargs[:external_id] == "of-fail"

        original.call(**kwargs)
      end

      expect do
        described_class.run!(now:, logger:)
      end.to output(/dropping baseline item snapshot/).to_stderr

      # The failing row passes through Outbox::IsolatedWrite's bounded
      # retry; the ok row runs once after the failure is dropped. The
      # exact retry count is bounded by IsolatedWrite's schedule; we
      # assert the ok row succeeds and the failed one is absent.
      expect(attempt).to be >= 2
      expect(OutboxEntry.where(record_kind: "item").pluck(:external_id)).to eq(["of-ok"])
    end

    it "uses a stable fallback timestamp when no source modification time is set" do
      item_class = stub_item_class(const_name: "BaselineItemNoLastModified", provider: "Omnifocus")
      item = item_class.create!(
        title: "Buy milk",
        external_id: "of-no-lm",
        options: options.merge(service_name: "Omnifocus")
      )
      item.update_columns(last_modified: nil, created_at: Time.zone.parse("2026-09-15T00:00:00Z"))

      described_class.run!(now:)

      row = OutboxEntry.find_by(record_kind: "item", external_id: "of-no-lm")
      expect(row.idempotency_key).to end_with(":snapshot:2026-09-15T00:00:00.000000Z")
    end

    it "ignores updated_at so live-sync writes between reruns don't change the idempotency key" do
      item_class = stub_item_class(const_name: "BaselineItemStableAcrossWrites", provider: "Omnifocus")
      first_modified = Time.zone.parse("2026-09-15T00:00:00Z")
      item = item_class.create!(
        title: "Buy milk",
        external_id: "of-stable",
        last_modified: first_modified,
        options: options.merge(service_name: "Omnifocus")
      )

      described_class.run!(now:)
      first_key = OutboxEntry.find_by(record_kind: "item").idempotency_key

      # Simulate a live sync saving the item between reruns by bumping
      # `updated_at`. The backfill's idempotency key must NOT change.
      item.update_columns(updated_at: Time.zone.parse("2030-01-01T00:00:00Z"))
      described_class.run!(now:)

      new_key = OutboxEntry.find_by(record_kind: "item").idempotency_key
      expect(new_key).to eq(first_key)
    end

    it "is a no-op in --pretend mode" do
      item_class = stub_item_class(const_name: "BaselineItemPretend", provider: "Omnifocus")
      item_class.create!(
        title: "Buy milk",
        external_id: "of-pretend",
        last_modified: Time.zone.parse("2026-10-07T00:00:00Z"),
        options: options.merge(service_name: "Omnifocus")
      )
      Thread.current[:global_options] = options.merge(pretend: true)

      counts = described_class.run!(now:)

      expect(counts[:items_emitted]).to eq(0)
      expect(OutboxEntry.count).to eq(0)
    end
  end
end
