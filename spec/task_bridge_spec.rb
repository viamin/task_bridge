# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaskBridge do
  describe ".digest_key" do
    it "uses the configured task_bridge setting when present" do
      allow(Chamber).to receive(:dig).with(:task_bridge, :digest_key).and_return("configured-deployment-secret")

      expect(described_class.digest_key).to eq("configured-deployment-secret")
    end

    it "falls back to the deployment's secret_key_base when unset" do
      allow(Chamber).to receive(:dig).with(:task_bridge, :digest_key).and_return(nil)

      expect(described_class.digest_key).to eq(Rails.application.secret_key_base)
    end

    it "ignores blank configuration" do
      allow(Chamber).to receive(:dig).with(:task_bridge, :digest_key).and_return("")

      expect(described_class.digest_key).to eq(Rails.application.secret_key_base)
    end
  end
end
