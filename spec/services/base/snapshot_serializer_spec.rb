# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::SnapshotSerializer do
  let(:item_class) do
    stub_const("SnapshotSerializerSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "TestService"
      end

      def external_data
        {}
      end
    end)
  end
  let(:item) do
    item_class.new(title: "Buy milk", external_id: "snap-1", notes:)
  end

  def digest_of(content)
    OpenSSL::HMAC.hexdigest("SHA256", TaskBridge.digest_key, content)
  end

  describe "notes_digest" do
    let(:notes) { "asana_id: snap-1\ncall bob about the invoice" }

    it "publishes a keyed digest of the metadata-stripped notes" do
      snapshot = described_class.call(item)

      expect(snapshot[:notes_digest]).to eq(digest_of("call bob about the invoice"))
    end

    it "is not a bare, offline-guessable hash of the notes content" do
      snapshot = described_class.call(item)

      expect(snapshot[:notes_digest]).not_to eq(Digest::SHA256.hexdigest("call bob about the invoice"))
    end

    it "changes when the notes content changes" do
      expect(described_class.call(item)[:notes_digest])
        .not_to eq(described_class.call(item_class.new(title: "Buy milk", external_id: "snap-1", notes: "call alice"))[:notes_digest])
    end

    it "is omitted when the notes carry no content after metadata stripping" do
      metadata_only = item_class.new(title: "Buy milk", external_id: "snap-1", notes: "asana_id: snap-1")

      expect(described_class.call(metadata_only)[:notes_digest]).to be_nil
    end
  end

  # Diff baselines written by the sync flow and by the #222 backfill are
  # compared byte-for-byte, so both render through `.published`.
  describe ".published" do
    let(:notes) { "call bob about the invoice" }
    let(:published_item) do
      item_class.new(
        title: "Buy milk",
        external_id: "snap-1",
        notes:,
        due_at: Time.zone.parse("2026-10-06T17:00:00Z"),
        completed_at: Time.zone.parse("2026-10-05T09:30:00.123456Z")
      )
    end

    it "renders timestamps as ISO 8601 UTC strings with microsecond precision" do
      snapshot = described_class.published(published_item)

      expect(snapshot.values_at(:due_at, :completed_at))
        .to eq(["2026-10-06T17:00:00.000000Z", "2026-10-05T09:30:00.123456Z"])
    end

    it "keeps absent timestamps absent rather than rendering them" do
      snapshot = described_class.published(published_item)

      expect(snapshot[:observed_at]).to be_nil
      expect(snapshot[:start_at]).to be_nil
    end

    it "leaves non-timestamp values untouched" do
      snapshot = described_class.published(published_item)

      expect(snapshot).to include(
        version: described_class::VERSION,
        entity_type: "task",
        title: "Buy milk",
        display_title: "Buy milk",
        completed: false,
        is_deleted: false,
        notes_digest: digest_of("call bob about the invoice")
      )
      expect(snapshot[:sub_item_keys]).to be_nil
    end

    it "keeps the serialized shape of `.call` so baselines compare byte-for-byte" do
      expect(described_class.published(published_item).keys).to eq(described_class.call(published_item).keys)
    end

    it "survives a JSON round-trip without losing rendered precision" do
      published = described_class.published(published_item)

      expect(JSON.parse(published.to_json)).to eq(published.deep_stringify_keys)
    end
  end
end
