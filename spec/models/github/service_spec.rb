# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Github::Service" do
  let(:service) { Github::Service.new }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: {data: {task: external_task.to_json}}.to_json) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#sync_to_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new }

      it "responds to #sync_to_primary" do
        expect(service).to be_respond_to(:sync_to_primary)
      end
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync }
  end

  describe "#should_sync?" do
    subject { service.should_sync?(task_updated_at) }

    context "when task_updated_at is nil" do
      let(:task_updated_at) { nil }

      context "when last sync was less than min_sync_interval" do
        let(:last_sync) { Time.now - Chronic.parse("29 minutes ago") }

        it { is_expected.to be false }
      end

      context "when last sync was more than min_sync_interval" do
        let(:last_sync) { Time.now - Chronic.parse("61 minutes ago") }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("29 minutes ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("61 minutes ago") }

      it { is_expected.to be false }
    end
  end
end
