# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::Mapping do
  let(:valid_sync_collection) { { sync_collection_id: 84, title: "Release checklist" } }
  let(:valid_member) do
    {
      item_key: "github:repo-1:issue-42",
      service_type: "github",
      service_instance: "github:repo-1",
      external_id: "issue-42"
    }
  end

  let(:valid_attrs) do
    {
      idempotency_key: "tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42:2026-08-14T19:21:00.000000Z",
      mapping_type: "representation_membership",
      observed_at: "2026-08-14T19:21:00.000000Z",
      sync_collection: valid_sync_collection,
      member: valid_member
    }
  end

  describe "required field validation" do
    it "raises when idempotency_key is blank" do
      expect { described_class.new(**valid_attrs, idempotency_key: "") }.to raise_error(ArgumentError, /idempotency_key/)
    end

    it "raises when mapping_type is invalid" do
      expect { described_class.new(**valid_attrs, mapping_type: "unknown") }.to raise_error(ArgumentError, /mapping_type/)
    end

    it "raises when observed_at is nil" do
      expect { described_class.new(**valid_attrs, observed_at: nil) }.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when observed_at is a blank string" do
      expect { described_class.new(**valid_attrs, observed_at: "") }.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when sync_collection is nil" do
      expect { described_class.new(**valid_attrs, sync_collection: nil) }.to raise_error(ArgumentError, /sync_collection/)
    end

    it "raises when sync_collection is not a hash" do
      expect { described_class.new(**valid_attrs, sync_collection: "collection 84") }
        .to raise_error(ArgumentError, /sync_collection must be a hash/)
    end

    it "raises when sync_collection_id is missing" do
      expect { described_class.new(**valid_attrs, sync_collection: { title: "no id" }) }.to raise_error(ArgumentError, /sync_collection_id/)
    end

    it "raises when sync_collection_id is blank" do
      expect { described_class.new(**valid_attrs, sync_collection: { sync_collection_id: "" }) }
        .to raise_error(ArgumentError, /sync_collection_id/)
    end

    it "raises when member is nil" do
      expect { described_class.new(**valid_attrs, member: nil) }.to raise_error(ArgumentError, /member/)
    end

    it "raises when member is not a hash" do
      expect { described_class.new(**valid_attrs, member: "github:repo-1:issue-42") }
        .to raise_error(ArgumentError, /member must be a hash/)
    end

    it "raises when member is missing required fields" do
      expect do
        described_class.new(**valid_attrs, member: { item_key: "x" })
      end.to raise_error(ArgumentError, /member/)
    end

    it "raises when mapping_confidence is invalid" do
      expect do
        described_class.new(**valid_attrs, mapping_confidence: "unknown_confidence")
      end.to raise_error(ArgumentError, /mapping_confidence/)
    end

    it "raises when membership_role is invalid" do
      expect do
        described_class.new(**valid_attrs, membership_role: "owner")
      end.to raise_error(ArgumentError, /membership_role/)
    end

    it "raises when mapping_source is not a string" do
      expect do
        described_class.new(**valid_attrs, mapping_source: :title_match)
      end.to raise_error(ArgumentError, /mapping_source must be a string/)
    end

    it "raises when sync_collection title is not a string" do
      expect do
        described_class.new(**valid_attrs, sync_collection: { sync_collection_id: 84, title: 84 })
      end.to raise_error(ArgumentError, /sync_collection\.title must be a string/)
    end

    it "raises when provenance is not a hash" do
      expect { described_class.new(**valid_attrs, provenance: "matched by title") }
        .to raise_error(ArgumentError, /provenance/)
    end
  end

  describe "#to_payload" do
    subject(:payload) { described_class.new(**valid_attrs).to_payload }

    it "includes contract_version 1" do
      expect(payload[:contract_version]).to eq(1)
    end

    it "includes sync_collection and member" do
      expect(payload[:sync_collection]).to eq(valid_sync_collection)
      expect(payload[:member]).to eq(valid_member)
    end

    it "omits nil optional fields" do
      expect(payload.keys).not_to include(:membership_role, :mapping_confidence, :provenance)
    end

    it "includes optional fields when provided" do
      mapping = described_class.new(
        **valid_attrs,
        membership_role: "member",
        mapping_confidence: "tentative",
        mapping_source: "title_match",
        provenance: { matched_fields: ["title"] }
      )
      p = mapping.to_payload
      expect(p[:membership_role]).to eq("member")
      expect(p[:mapping_confidence]).to eq("tentative")
      expect(p[:provenance]).to eq({ matched_fields: ["title"] })
    end

    it "accepts all valid confidence levels" do
      %w[confirmed inferred tentative].each do |level|
        expect { described_class.new(**valid_attrs, mapping_confidence: level) }.not_to raise_error
      end
    end

    it "accepts all valid membership roles" do
      %w[canonical member].each do |role|
        expect { described_class.new(**valid_attrs, membership_role: role) }.not_to raise_error
      end
    end
  end

  describe "RECORD_KIND" do
    it "is 'mapping'" do
      expect(described_class::RECORD_KIND).to eq("mapping")
    end
  end
end
