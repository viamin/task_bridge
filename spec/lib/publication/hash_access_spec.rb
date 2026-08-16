# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::HashAccess do
  describe ".fetch" do
    it "returns the symbol-keyed value when present" do
      expect(described_class.fetch({ enabled: false }, :enabled)).to be(false)
    end

    it "falls back to the string-keyed value when the symbol key is absent" do
      expect(described_class.fetch({ "enabled" => false }, :enabled)).to be(false)
    end
  end

  describe ".key?" do
    it "checks both symbol and string keys" do
      expect(described_class.key?({ "enabled" => true }, :enabled)).to be(true)
    end
  end
end
