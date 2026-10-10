# frozen_string_literal: true

require "rails_helper"

RSpec.describe Disappearance::Detector do
  let(:sync_item_class) do
    stub_const("DetectorSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "DetectorService"
      end

      def external_data
        {}
      end
    end)
  end
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: Time.current - 1.hour) }
  let(:options) do
    { logger:, quiet: true, pretend: false, debug: false, primary: "Omnifocus", services: [], tags: ["TaskBridge"] }
  end
  let(:service_class) do
    stub_const("DetectorSpecService", Class.new(Base::Service) do
      attr_accessor :detector_strategy, :scope_available, :authorized, :verifier

      def friendly_name
        "DetectorService"
      end

      def item_class
        DetectorSpecItem
      end

      def sync_strategies
        [:to_primary]
      end

      def min_sync_interval
        60
      end

      def items_to_sync(*, **)
        []
      end

      def deletion_detection_strategy
        detector_strategy
      end

      def deletion_detection_scope_available?
        scope_available
      end

      def verify_missing_item(item)
        verifier.call(item)
      end
    end)
  end
  let(:service) do
    service_class.new(options:).tap do |service|
      service.detector_strategy = strategy
      service.scope_available = true
      service.verifier = verifier
    end
  end
  let(:strategy) { Disappearance::Strategy.full_list_absence(state: "source_deleted", confidence: "high") }
  let(:verifier) { ->(_item) {} }
  let(:observed_at) { Time.zone.parse("2026-10-05T19:30:00Z") }
  let(:sync_run_id) { "sync-run-20261005T193000Z-detector_service" }

  def persisted_item(external_id, attributes = {})
    sync_item_class.create!(
      { external_id:, title: "Item #{external_id}", source_service_name: service.service_name }.merge(attributes)
    )
  end

  def observed_wrapper(external_id)
    sync_item_class.new(external_id:, source_service_name: service.service_name)
  end

  def record_with(observed_items, complete_fetch: true, at: observed_at)
    described_class.record!(
      service:,
      observed_items:,
      complete_fetch:,
      observed_at: at
    )
  end

  def observations
    OutboxEntry.where(record_kind: "observation")
  end

  before do
    Thread.current[:global_options] = nil
  end

  describe "a full-list absence strategy" do
    it "enqueues a tombstone for the missing item only" do
      missing_item = persisted_item("det-missing")
      persisted_item("det-present")

      entries = record_with([observed_wrapper("det-present")])

      expect(entries.length).to eq(1)
      entry = entries.first
      expect(entry.event_type).to eq("deleted")
      expect(entry.external_id).to eq("det-missing")
      expect(entry.observed_at).to eq(observed_at)
      expect(entry.payload["disappearance_state"]).to eq("source_deleted")
      expect(entry.payload["is_deleted"]).to be(true)
      expect(entry.payload["item_key"]).to eq(missing_item.item_key)
      expect(entry.payload["source"]).to match(
        hash_including(
          "service_type" => "detector_service",
          "service_instance" => service.service_name,
          "external_id" => "det-missing"
        )
      )
    end

    it "preserves the local row and records the marker instead of deleting" do
      missing_item = persisted_item("det-missing")

      record_with([observed_wrapper("det-present")])

      expect(sync_item_class.exists?(missing_item.id)).to be(true)
      expect(missing_item.reload.disappearance_observation).to match(
        hash_including(
          "state" => "source_deleted",
          "observed_at" => observed_at.utc.iso8601(6),
          "sync_run_id" => sync_run_id
        )
      )
    end

    it "carries last-known facts and provenance in the payload" do
      persisted_item("det-missing")

      entry = record_with([]).first

      expect(entry.payload["last_known"]).to match(
        hash_including("title" => "Item det-missing", "status" => "open")
      )
      expect(entry.payload["provenance"]).to match(
        hash_including(
          "detected_by" => "missing_from_full_list",
          "confidence" => "high",
          "detection_strategy" => "full_list_absence",
          "sync_run_id" => sync_run_id
        )
      )
    end

    it "stamps tombstones with the run-scoped id when detection runs inside a sync run" do
      persisted_item("det-missing")
      run_scoped_service = service_class.new(options: options.merge(sync_started_at: "2026-10-05T19:20:00.000000Z"))
      run_scoped_service.detector_strategy = strategy
      run_scoped_service.scope_available = true
      run_scoped_service.verifier = verifier

      entry = described_class.record!(
        service: run_scoped_service, observed_items: [], complete_fetch: true, observed_at: observed_at
      ).first

      expect(entry.payload["provenance"]["sync_run_id"]).to eq("sync-run-20261005T192000Z-detector_service")
    end

    it "does not re-emit the same state on a later run" do
      persisted_item("det-missing")
      record_with([])

      later_entries = record_with([], at: observed_at + 1.hour)

      expect(later_entries).to be_empty
      expect(observations.count).to eq(1)
    end

    it "emits a new observation when the state changes" do
      persisted_item("det-missing")
      record_with([])
      service.detector_strategy = Disappearance::Strategy.filtered_with_verification
      service.verifier = ->(_item) { Disappearance::Finding.new(state: "source_deleted", confidence: "high") }

      # The same state verified again stays suppressed
      expect(record_with([], at: observed_at + 1.hour)).to be_empty

      service.verifier = ->(_item) { Disappearance::Finding.new(state: "no_longer_visible", confidence: "medium") }
      entries = record_with([], at: observed_at + 2.hours)

      expect(entries.length).to eq(1)
      expect(entries.first.payload["disappearance_state"]).to eq("no_longer_visible")
      expect(observations.count).to eq(2)
    end

    it "treats sub-items of observed parents as observed" do
      persisted_item("det-sub")
      parent = observed_wrapper("det-parent")
      def parent.sub_items
        [DetectorSpecItem.new(external_id: "det-sub")]
      end

      entries = record_with([parent])

      expect(entries.map(&:external_id)).not_to include("det-sub")
    end

    it "skips persisted rows without an external id" do
      persisted_item(nil)

      expect(record_with([])).to be_empty
    end
  end

  describe "a filtered strategy with verification" do
    let(:strategy) { Disappearance::Strategy.filtered_with_verification }

    it "emits the finding returned by the adapter's verification" do
      persisted_item("det-verify")
      service.verifier = ->(_item) { Disappearance::Finding.new(state: "source_archived", confidence: "high") }

      entry = record_with([]).first

      expect(entry.payload["disappearance_state"]).to eq("source_archived")
      expect(entry.payload["is_deleted"]).to be(false)
      expect(entry.payload["provenance"]).to match(
        hash_including("detected_by" => "direct_source_lookup", "confidence" => "high")
      )
    end

    it "merges finding detail into the provenance payload" do
      persisted_item("det-verify")
      service.verifier = lambda { |_item|
        Disappearance::Finding.new(state: "source_deleted", confidence: "high", detail: { "lookup_status" => 404 })
      }

      entry = record_with([]).first

      expect(entry.payload["provenance"]).to include("lookup_status" => 404)
    end

    it "emits nothing and records no marker when verification is inconclusive" do
      missing_item = persisted_item("det-verify")
      service.verifier = ->(_item) {}

      expect(record_with([])).to be_empty
      expect(observations.count).to eq(0)
      expect(missing_item.reload.disappearance_observation).to be_nil
    end

    it "skips items the adapter rules out as candidates" do
      persisted_item("det-verify")
      allow(service).to receive(:disappearance_candidate?).and_return(false)

      expect(record_with([])).to be_empty
      expect(observations.count).to eq(0)
    end
  end

  describe "suppression guards" do
    it "emits nothing for a disabled strategy" do
      persisted_item("det-guard")
      service.detector_strategy = Disappearance::Strategy.disabled

      expect(record_with([])).to be_empty
    end

    it "emits nothing for a partial fetch" do
      persisted_item("det-guard")

      expect(record_with([], complete_fetch: false)).to be_empty
    end

    it "emits nothing in pretend mode" do
      persisted_item("det-guard")
      service.options = options.merge(pretend: true)

      expect(record_with([])).to be_empty
      expect(observations.count).to eq(0)
    end

    it "emits nothing when the service is unauthorized" do
      persisted_item("det-guard")
      service.authorized = false

      expect(record_with([])).to be_empty
    end

    it "emits nothing when the detection scope was not fully readable" do
      persisted_item("det-guard")
      service.scope_available = false

      expect(record_with([])).to be_empty
    end
  end

  describe "reappearance" do
    it "clears the marker when the item is observed again, so a later disappearance re-emits" do
      item = persisted_item("det-return")
      record_with([])
      expect(item.reload.disappearance_observation).to be_present

      item.observe_source!(observed_at: observed_at + 1.hour)
      expect(item.reload.disappearance_observation).to be_nil

      expect(record_with([], at: observed_at + 2.hours).length).to eq(1)
      expect(observations.count).to eq(2)
    end
  end

  describe Disappearance::Finding do
    it "rejects unknown states" do
      expect do
        described_class.new(state: "vaporized", confidence: "high")
      end.to raise_error(ArgumentError, /unknown disappearance state/)
    end
  end

  describe Disappearance::Strategy do
    it "rejects unknown modes" do
      expect { described_class.new(mode: :gut_feeling) }.to raise_error(ArgumentError, /unknown detection mode/)
    end
  end
end
