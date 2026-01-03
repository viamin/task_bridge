# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Asana::Service", :full_options do
  let(:logger) { instance_double(StructuredLogger) }
  let(:options) { full_options.merge(logger: logger) }
  let(:service) { Asana::Service.new(options: options) }
  let(:min_sync_interval) { service.send(:min_sync_interval) }
  let(:last_sync_time) { Time.now - min_sync_interval }
  let(:interval_since_last_sync) { Time.now - last_sync_time }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).with("Asana", interval: true).and_return(interval_since_last_sync)
    allow(logger).to receive(:last_synced).with("Asana", interval: false).and_return(last_sync_time)
  end

  describe "#sync_with_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new(options: {}) }

      it "responds to #sync_with_primary" do
        expect(service).to be_respond_to(:sync_with_primary)
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

      context "when not enough time has passed since last sync" do
        let(:last_sync_time) { (Time.now - min_sync_interval) + 60.seconds }
        let(:interval_since_last_sync) { Time.now - last_sync_time }

        it { is_expected.to be false }
      end

      context "when enough time has passed since last sync" do
        let(:last_sync_time) { (Time.now - min_sync_interval) - 60.seconds }
        let(:interval_since_last_sync) { Time.now - last_sync_time }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("#{min_sync_interval - 1.second} seconds ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Time.now - (min_sync_interval + 1.minute) }

      it { is_expected.to be false }
    end
  end

  describe "#add_item" do
    subject { service.add_item(external_task, parent_task_gid) }

    let(:external_task) { nil }
    let(:parent_task_gid) { nil }
    let(:title) { "Test" }

    before do
      allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
    end

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end

  describe "#update_item" do
    subject { service.update_item(asana_task, external_task) }

    let(:asana_task) { nil }
    let(:external_task) { nil }

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end

  describe "#skip_create?" do
    subject { service.skip_create?(asana_task) }

    let(:asana_task_json) { JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))) }
    let(:asana_task) { Asana::Task.new(asana_task: asana_task_json, options:) }

    context "with a completed task" do
      before { allow(asana_task).to receive(:completed?).and_return(true) }

      it { is_expected.to be true }
    end

    context "with a incomplete task" do
      before { allow(asana_task).to receive(:completed?).and_return(false) }

      context "with a nil assignee" do
        before { allow(asana_task).to receive(:assignee).and_return(nil) }

        it { is_expected.to be false }
      end

      context "with an assignee that matches asana_user" do
        before do
          allow(asana_task).to receive(:assignee).and_return("123")
          allow(service).to receive(:asana_user).and_return({ gid: "123" }.stringify_keys)
        end

        it { is_expected.to be false }
      end

      context "with an assignee that does not match asana_user" do
        before do
          allow(asana_task).to receive(:assignee).and_return("123")
          allow(service).to receive(:asana_user).and_return({ gid: "456" }.stringify_keys)
        end

        it { is_expected.to be true }
      end
    end
  end

  describe "#friendly_name" do
    it "returns the expected identifier" do
      expect(service.friendly_name).to eq("Asana")
    end
  end

  describe "#sync_strategies" do
    it "supports two way syncing" do
      expect(service.sync_strategies).to eq([:two_way])
    end
  end
end
