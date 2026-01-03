# frozen_string_literal: true

require "spec_helper"

RSpec.describe GoogleTasks::BaseCli do
  subject(:cli) { described_class.new }

  describe "#client_secrets_path" do
    context "when the value is configured in Chamber" do
      before do
        allow(Chamber).to receive(:dig).with(:google, :client_secrets_file).and_return("/tmp/client.json")
        allow(Chamber).to receive(:dig!).with(:google, :client_secrets_file).and_return("/tmp/client.json")
      end

      it "returns the configured path" do
        expect(cli.send(:client_secrets_path)).to eq("/tmp/client.json")
      end
    end
  end

  describe "#token_store_path" do
    before do
      allow(Chamber).to receive(:dig).with(:google, :client_secrets_file).and_return(nil)
      allow(Chamber).to receive(:dig).with(:google, :credential_store).and_return("/tmp/credentials.yaml")
      allow(Chamber).to receive(:dig!).with(:google, :credential_store).and_return("/tmp/credentials.yaml")
    end

    it "falls back to the configured credential store" do
      expect(cli.send(:token_store_path)).to eq("/tmp/credentials.yaml")
    end
  end

  describe "#well_known_path_for" do
    before { allow(OS).to receive(:windows?).and_return(false) }

    it "builds the expected path in the home directory" do
      expect(cli.send(:well_known_path_for, "credentials.yaml")).to eq(File.join(Dir.home, ".config", "google", "credentials.yaml"))
    end
  end
end
