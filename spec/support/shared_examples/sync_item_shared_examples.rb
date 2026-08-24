# frozen_string_literal: true

RSpec.shared_examples "sync_item" do
  context "when creating a new item" do
    it "creates accessors for notes attributes" do
      item.send(:all_services, remove_current: true).each do |service|
        expect(item).to respond_to(:"#{service.underscore}_id")
        expect(item).to respond_to(:"#{service.underscore}_url")
      end
    end
  end
end

RSpec.shared_examples "normalized_snapshot" do
  describe "#normalized_snapshot" do
    before { item.read_original }

    it "returns a versioned, deterministic hash" do
      snapshot = item.normalized_snapshot

      expect(snapshot[:version]).to eq(Base::SnapshotSerializer::VERSION)
      expect(snapshot).to eq(item.normalized_snapshot)
    end

    it "identifies the item and its source without external calls" do
      snapshot = item.normalized_snapshot

      expect(snapshot[:item_key]).to eq(item.item_key)
      expect(snapshot[:entity_type]).to eq("task")
      expect(snapshot[:source]).to include(
        service_type: Base::Service.service_identifier_for(item.provider),
        external_id: item.external_id
      )
    end

    it "carries common current-state fields" do
      snapshot = item.normalized_snapshot

      expect(snapshot[:title]).to eq(item.title)
      # Notes are opt-in per source under the publication contract (#215)
      # and the per-source setting does not exist yet, so the snapshot must
      # not carry any notes field today.
      expect(snapshot).not_to have_key(:notes)
      expect(snapshot).not_to have_key(:notes_preview)
      expect(snapshot[:status]).to be_in(%w[open completed dropped])
      expect(snapshot[:completed]).to eq(item.completed?)
      expect(snapshot[:tags]).to eq(Array(item.tags))
    end

    it "puts source-specific facts under metadata" do
      snapshot = item.normalized_snapshot

      expect(snapshot[:metadata]).to eq(item.normalized_metadata)
    end
  end
end
