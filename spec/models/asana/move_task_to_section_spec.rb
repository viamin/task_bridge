# frozen_string_literal: true

require "spec_helper"

RSpec.describe Asana::Service do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}) }
  let(:options) do
    {
      logger: logger,
      services: [],
      sync_started_at: "2024-01-01 09:00AM",
      quiet: true,
      debug: false
    }
  end

  subject(:service) { described_class.new(options:) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(Chamber).to receive(:dig!).and_call_original
    allow(Chamber).to receive(:dig!).with(:asana, :personal_access_token).and_return("token")
  end

  describe "#move_task_to_section" do
    context "when no section is provided" do
      it "returns nil without issuing a request" do
        expect(HTTParty).not_to receive(:post)
        expect(service.send(:move_task_to_section, nil, "123")).to be_nil
      end
    end

    context "when the API request succeeds" do
      it "returns nil" do
        response = instance_double(HTTParty::Response, success?: true)
        allow(HTTParty).to receive(:post).and_return(response)

        expect(service.send(:move_task_to_section, "section_gid", "task_gid")).to be_nil
      end
    end

    context "when the API request fails" do
      it "returns a failure message including the response code" do
        response = instance_double(HTTParty::Response, success?: false, code: 500, body: "boom")
        allow(HTTParty).to receive(:post).and_return(response)

        result = service.send(:move_task_to_section, "section_gid", "task_gid")

        expect(result).to eq("Failed to move an Asana task to a section - code 500")
      end
    end
  end
end
