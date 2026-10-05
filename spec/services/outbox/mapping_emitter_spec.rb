# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::MappingEmitter do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:collection) { SyncCollection.create!(title: "Release checklist", mapping_method: "manual_backfill", mapping_confidence: "low") }
  let(:member_class) do
    stub_const("MappingSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Github"
      end

      def external_data
        {}
      end
    end)
  end
  let(:member) do
    member_class.create!(
      title: "Release checklist",
      external_id: "issue-42",
      options: { service_name: "Github:repo-1", services: [], primary: "PrimaryService", tags: [] }
    )
  end
  let(:service_class) do
    Class.new(Base::Service) do
      def friendly_name
        "Test Service"
      end

      def item_class
        MappingSpecItem
      end

      def sync_strategies
        [:to_primary]
      end

      def items_to_sync(*, **)
        []
      end

      def add_item(*)
        nil
      end

      def min_sync_interval
        60
      end
    end
  end
  let(:service) { service_class.new(options: { quiet: true, pretend: false, services: [], primary: "Asana", tags: [] }) }

  before { member_class }

  describe ".emit_for_members" do
    it "enqueues a mapping row for each persisted member" do
      described_class.emit_for_members(collection, members: [member], observed_at:)

      row = OutboxEntry.find_by(record_kind: "mapping")
      expect(row).to have_attributes(
        external_id: "issue-42",
        service_type: "github",
        service_instance: "github:repo-1",
        sync_collection_id: collection.id,
        observed_at:
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{collection.id}:membership:github:repo-1:issue-42:2026-10-05T10:00:00.000000Z"
      )
      expect(row.payload).to include(
        "mapping_type" => "representation_membership",
        "membership_role" => "member",
        "mapping_confidence" => "tentative",
        "mapping_source" => "manual"
      )
      expect(row.payload["sync_collection"]).to include("sync_collection_id" => collection.id, "title" => "Release checklist")
      expect(row.payload["member"]).to include(
        "item_key" => "github_repo_1:issue-42",
        "service_type" => "github",
        "service_instance" => "github:repo-1",
        "external_id" => "issue-42"
      )
      expect(member.normalized_snapshot[:source]).to eq(Outbox::SourceIdentity.for(member))
      expect(row.payload["provenance"]).to include("method" => "manual_backfill", "confidence" => "low")
    end

    it "translates sync-id and created-by-sync provenance to confirmed mappings" do
      aggregate_failures do
        collection.update!(mapping_method: "source_sync_id", mapping_confidence: "high")
        described_class.emit_for_members(collection, members: [member], observed_at:)
        expect(OutboxEntry.find_by(record_kind: "mapping").payload.values_at("mapping_confidence", "mapping_source"))
          .to eq(%w[confirmed sync_id_note])

        collection.update!(mapping_method: "created_by_sync", mapping_confidence: "high")
        described_class.emit_for_members(collection, members: [member], observed_at: observed_at + 1.minute)
        expect(OutboxEntry.where(record_kind: "mapping").last.payload.values_at("mapping_confidence", "mapping_source"))
          .to eq(%w[confirmed created_by_sync])
      end
    end

    it "skips members that are not persisted sync items" do
      transient = member_class.new(external_id: "issue-43")

      described_class.emit_for_members(collection, members: [transient, nil, "not-an-item"], observed_at:)

      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
    end

    it "isolates a failing member write and still publishes the remaining members" do
      second_member = member_class.create!(
        title: "Release checklist",
        external_id: "issue-99",
        options: { service_name: "Github:repo-1", services: [], primary: "PrimaryService", tags: [] }
      )
      allow(OutboxEntry).to receive(:enqueue).and_wrap_original do |original, record_kind:, payload:, **context|
        raise ActiveRecord::ActiveRecordError, "simulated outbox failure" if context[:external_id] == "issue-42"

        original.call(record_kind:, payload:, **context)
      end

      expect do
        described_class.emit_for_members(collection, members: [member, second_member], observed_at:)
      end.to output(/dropping mapping for github_repo_1:issue-42/).to_stderr

      expect(OutboxEntry.where(record_kind: "mapping").map(&:external_id)).to eq(["issue-99"])
    end
  end

  describe "sync flow integration" do
    let(:peer_class) do
      stub_const("MappingPeerSpecItem", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        def provider
          "PrimaryService"
        end

        def external_data
          {}
        end
      end)
    end
    let(:additional_peer_class) do
      stub_const("MappingAdditionalPeerSpecItem", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        def provider
          "AdditionalService"
        end

        def external_data
          {}
        end
      end)
    end
    let(:peer_item) { peer_class.create!(title: "Release checklist", external_id: "primary-42") }

    before do
      peer_class
      additional_peer_class
    end

    it "emits mapping rows when two representations join the same sync collection" do
      travel_to(observed_at) do
        service.send(:persist_sync_collection_for, member, peer_item)
      end

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.map(&:external_id)).to contain_exactly("issue-42", "primary-42")
      expect(rows.map(&:sync_collection_id)).to eq([member.reload.sync_collection_id] * 2)
    end

    it "does not re-emit mapping rows for an unchanged membership" do
      travel_to(observed_at) { service.send(:persist_sync_collection_for, member, peer_item) }

      expect do
        travel_to(observed_at + 1.hour) { service.send(:persist_sync_collection_for, member, peer_item) }
      end.not_to(change { OutboxEntry.where(record_kind: "mapping").count })
    end

    it "re-emits for every member when mapping provenance upgrades" do
      travel_to(observed_at) { service.send(:persist_sync_collection_for, member, peer_item) }

      member.update!(notes: "primary_service_id: primary-42")
      member.read_notes # a refreshed item carries note components in memory

      expect do
        travel_to(observed_at + 1.hour) { service.send(:persist_sync_collection_for, member, peer_item) }
      end.to change { OutboxEntry.where(record_kind: "mapping").count }.by(2)

      upgraded = OutboxEntry.where(record_kind: "mapping").last(2)
      expect(upgraded.map { |row| row.payload["mapping_source"] }).to all(eq("sync_id_note"))
    end

    it "re-emits existing members when an upgrade also links a new member" do
      travel_to(observed_at) { service.send(:persist_sync_collection_for, member, peer_item) }

      member.update!(notes: "primary_service_id: primary-42")
      member.read_notes
      new_peer = additional_peer_class.create!(title: "Release checklist", external_id: "additional-43")

      expect do
        travel_to(observed_at + 1.hour) { service.send(:persist_sync_collection_for, member, peer_item, new_peer) }
      end.to change { OutboxEntry.where(record_kind: "mapping").count }.by(3)

      upgraded = OutboxEntry.where(record_kind: "mapping").last(3)
      expect(upgraded.map(&:external_id)).to contain_exactly("issue-42", "primary-42", "additional-43")
      expect(upgraded.map { |row| row.payload["mapping_source"] }).to all(eq("sync_id_note"))
    end
  end
end
