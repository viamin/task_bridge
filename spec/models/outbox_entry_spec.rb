# frozen_string_literal: true

require "rails_helper"

RSpec.describe OutboxEntry, type: :model do
  let(:payload) do
    {
      "contract_version" => 1,
      "event_type" => "source_changed",
      "item_key" => "asana:workspace-12345:default:1201234567890"
    }
  end
  let(:enqueue_attributes) do
    {
      record_kind: :observation,
      event_type: "source_changed",
      service_type: "asana",
      service_instance: "asana:workspace-12345:default",
      external_id: "1201234567890",
      observed_at: Time.zone.parse("2026-08-14T19:20:31.123456Z"),
      payload:
    }
  end

  # Keep the thread-local global options hermetic: enqueue reads the run's
  # --pretend flag through GlobalOptions.
  before { Thread.current[:global_options] = { pretend: false } }

  def enqueue_entry(overrides = {})
    described_class.enqueue(**enqueue_attributes, **overrides)
  end

  describe ".enqueue" do
    it "enqueues a pending entry with a derived idempotency key" do
      entry = enqueue_entry

      expect(entry).to be_pending
      expect(entry).to be_persisted
      expect(entry.idempotency_key).to eq(
        "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z"
      )
      expect(entry.payload).to eq(payload)
      expect(entry.payload_version).to eq(1)
      expect(entry.attempts).to eq(0)
    end

    it "does not duplicate an observation that is already enqueued" do
      first_entry = enqueue_entry
      second_entry = enqueue_entry

      expect(second_entry.id).to eq(first_entry.id)
      expect(described_class.count).to eq(1)
    end

    it "does not reset delivery state when a delivered row is re-enqueued" do
      first_entry = enqueue_entry
      first_entry.mark_delivered!

      second_entry = enqueue_entry

      expect(second_entry.id).to eq(first_entry.id)
      expect(second_entry).to be_delivered
      expect(described_class.count).to eq(1)
    end

    it "uses an explicit idempotency key when one is provided" do
      entry = enqueue_entry(idempotency_key: "tb:v1:custom:key")

      expect(entry.idempotency_key).to eq("tb:v1:custom:key")
    end

    it "enqueues item snapshots without an event type" do
      entry = enqueue_entry(
        record_kind: :item,
        event_type: nil,
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        external_id: "task-77",
        payload: { "contract_version" => 1, "item_key" => "omnifocus:default:task-77" }
      )

      expect(entry).to be_pending
      expect(entry.record_kind).to eq("item")
      expect(entry.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:task-77:snapshot:2026-08-14T19:20:31.123456Z"
      )
    end

    it "enqueues mapping rows scoped to a sync collection" do
      collection = SyncCollection.create!(title: "Release checklist")

      entry = enqueue_entry(
        record_kind: :mapping,
        event_type: nil,
        service_type: "github",
        service_instance: "github:repo-1",
        external_id: "issue-42",
        sync_collection_id: collection.id,
        payload: { "contract_version" => 1, "mapping_type" => "representation_membership" }
      )

      expect(entry.sync_collection_id).to eq(collection.id)
      expect(entry.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{collection.id}:membership:github:repo-1:issue-42:2026-08-14T19:20:31.123456Z"
      )
    end

    it "enqueues sync-run summaries scoped by their run id" do
      entry = enqueue_entry(
        record_kind: :sync_run,
        event_type: nil,
        service_type: "asana",
        service_instance: "asana:workspace-12345:default",
        external_id: nil,
        sync_run_id: "sync-run-20260814T192000Z-asana",
        payload: { "contract_version" => 1, "sync_run_id" => "sync-run-20260814T192000Z-asana" }
      )

      expect(entry.record_kind).to eq("sync_run")
      expect(entry.idempotency_key).to eq(
        "tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana"
      )
    end

    it "raises KeyError when the source identity is missing" do
      expect do
        described_class.enqueue(record_kind: :observation, payload:)
      end.to raise_error(KeyError)
    end

    it "rejects unknown context keys so typos do not silently drop context" do
      expect { enqueue_entry(service_instanse: "asana:default") }.to raise_error(ArgumentError, /service_instanse/)
    end

    context "when the run is in --pretend mode" do
      before { Thread.current[:global_options] = { pretend: true } }

      it "is a strict no-op and writes no outbox rows" do
        expect(enqueue_entry).to be_nil
        expect(described_class.count).to eq(0)
      end
    end
  end

  describe "validations" do
    def new_entry(overrides = {})
      attributes = {
        idempotency_key: "tb:v1:obs:asana:default:1201:snapshot_seen:2026-08-14T19:20:31.123456Z",
        record_kind: "observation",
        event_type: "snapshot_seen",
        service_type: "asana",
        service_instance: "asana:default",
        external_id: "1201",
        observed_at: Time.zone.parse("2026-08-14T19:20:31.123456Z"),
        payload:
      }
      described_class.new(attributes.merge(overrides))
    end

    it "is valid with the enqueue attributes" do
      expect(new_entry).to be_valid
    end

    it "requires an idempotency key" do
      entry = new_entry(idempotency_key: nil)

      expect(entry).not_to be_valid
      expect(entry.errors[:idempotency_key]).to be_present
    end

    it "requires a known record kind" do
      entry = new_entry(record_kind: "bogus")

      expect(entry).not_to be_valid
      expect(entry.errors[:record_kind]).to be_present
    end

    it "requires a known status" do
      entry = new_entry(status: "flown")

      expect(entry).not_to be_valid
      expect(entry.errors[:status]).to be_present
    end

    it "requires a known event type on observations" do
      entry = new_entry(event_type: "mutated")

      expect(entry).not_to be_valid
      expect(entry.errors[:event_type]).to be_present
    end

    it "does not require an event type on non-observation kinds" do
      entry = new_entry(record_kind: "item", event_type: nil)

      expect(entry).to be_valid
    end
  end

  describe "uniqueness enforcement" do
    it "lets the unique index reject a duplicate idempotency key" do
      enqueue_entry

      duplicate = described_class.new(
        record_kind: "observation",
        event_type: "snapshot_seen",
        service_type: "asana",
        service_instance: "asana:default",
        external_id: "1201234567890",
        observed_at: Time.zone.parse("2026-08-14T19:20:31.123456Z"),
        payload:
      )
      duplicate.idempotency_key = OutboxEntry.first.idempotency_key

      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "immutability" do
    it "keeps the canonical payload and record identity immutable after create" do
      entry = enqueue_entry

      expect { entry.update(payload: { "tampered" => true }) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect { entry.record_kind = "sync_run" }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(entry.reload.payload).to eq(payload)
      expect(entry.reload.record_kind).to eq("observation")
    end
  end

  describe "#mark_delivered!" do
    it "records delivery and clears any failure state" do
      entry = enqueue_entry
      entry.record_publication_failure!(
        error_class: "TaskBridgeWeb::TimeoutError",
        error_message: "connection timed out"
      )
      published_at = Time.zone.parse("2026-08-14T19:21:10Z")

      entry.mark_delivered!(at: published_at)

      expect(entry.reload).to be_delivered
      expect(entry.published_at).to eq(published_at)
      expect(entry.next_retry_at).to be_nil
      expect(entry.error_class).to be_nil
      expect(entry.error_message).to be_nil
    end
  end

  describe "#record_publication_failure!" do
    let(:now) { Time.zone.parse("2026-08-14T19:21:10Z") }

    it "keeps retryable failures pending with backoff, attempts, and the error" do
      entry = enqueue_entry

      entry.record_publication_failure!(
        error_class: "TaskBridgeWeb::TimeoutError",
        error_message: "connection timed out",
        now:
      )

      expect(entry.reload).to be_pending
      expect(entry.attempts).to eq(1)
      expect(entry.error_class).to eq("TaskBridgeWeb::TimeoutError")
      expect(entry.error_message).to eq("connection timed out")
      expect(entry.next_retry_at).to be_between(now + 1.minute, now + 75.seconds)
    end

    it "grows the retry backoff exponentially with each attempt" do
      entry = enqueue_entry
      entry.record_publication_failure!(error_class: "Error", error_message: "first", now:)
      entry.record_publication_failure!(error_class: "Error", error_message: "second", now:)

      expect(entry.attempts).to eq(2)
      expect(entry.next_retry_at).to be_between(now + 2.minutes, now + 150.seconds)
    end

    it "moves non-retryable failures to failed for operator review" do
      entry = enqueue_entry

      entry.record_publication_failure!(
        error_class: "TaskBridgeWeb::ConflictError",
        error_message: "idempotency key payload mismatch",
        retryable: false,
        now:
      )

      expect(entry.reload).to be_failed
      expect(entry.attempts).to eq(1)
      expect(entry.next_retry_at).to be_nil
      expect(entry.error_class).to eq("TaskBridgeWeb::ConflictError")
    end
  end

  describe "#retry!" do
    it "returns a terminal failure to pending for manual or scripted replay" do
      entry = enqueue_entry
      entry.record_publication_failure!(
        error_class: "TaskBridgeWeb::ConflictError",
        error_message: "terminal",
        retryable: false
      )

      entry.retry!

      expect(entry.reload).to be_pending
      expect(entry.next_retry_at).to be_nil
      expect(entry.error_class).to be_nil
      expect(entry.error_message).to be_nil
    end
  end

  describe ".due_for_publication" do
    it "returns pending rows without backoff or with elapsed backoff" do
      never_attempted = enqueue_entry(
        observed_at: Time.zone.parse("2026-08-14T19:00:00Z"),
        external_id: "1201234567891"
      )
      elapsed_backoff = enqueue_entry(
        observed_at: Time.zone.parse("2026-08-14T18:00:00Z"),
        external_id: "1201234567892"
      )
      elapsed_backoff.update_columns(next_retry_at: 1.minute.ago, attempts: 1)
      backing_off = enqueue_entry(
        observed_at: Time.zone.parse("2026-08-14T20:00:00Z"),
        external_id: "1201234567893"
      )
      backing_off.update_columns(next_retry_at: 1.hour.from_now, attempts: 1)
      delivered = enqueue_entry(
        observed_at: Time.zone.parse("2026-08-14T21:00:00Z"),
        external_id: "1201234567894"
      )
      delivered.update_columns(status: "delivered", published_at: Time.current)

      expect(described_class.due_for_publication).to contain_exactly(never_attempted, elapsed_backoff)
    end
  end
end
