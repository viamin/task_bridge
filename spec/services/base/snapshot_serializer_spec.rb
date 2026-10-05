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
end
