# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Asana::Service" do
  let(:service) { Asana::Service.new(options) }
  let(:options) { { logger: } }
  let(:logger)  { double(StructuredLogger) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#sync_with_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new({}) }

      it "responds to #sync_with_primary" do
        expect(service).to be_respond_to(:sync_with_primary)
      end
    end
  end

  describe "#tasks_to_sync" do
    subject { service.tasks_to_sync }
  end

  describe "#should_sync?" do
    subject { service.should_sync?(task_updated_at) }

    context "when task_updated_at is nil" do
      let(:task_updated_at) { nil }

      context "when last sync was less than min_sync_interval" do
        let(:last_sync) { Time.now - Chronic.parse("4 minutes ago") }

        it { is_expected.to be false }
      end

      context "when last sync was more than min_sync_interval" do
        let(:last_sync) { Time.now - Chronic.parse("6 minutes ago") }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("4 minutes ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("6 minutes ago") }

      it { is_expected.to be false }
    end
  end

  describe "#add_task" do
    subject { service.add_task(external_task, parent_task_gid) }

    let(:external_task) { nil }
    let(:parent_task_gid) { nil }
    let(:title) { "Test" }

    before do
      allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
    end

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end

    context "with Omnifocus task" do
      let(:external_task) { Omnifocus::Service.new.tasks_to_sync(projects: "TaskBridge:Test").first }

      context "with a regular task" do
      end

      context "with a task with a subtask" do
      end

      context "with a task in a section" do
      end
    end
  end

  describe "#update_task" do
    subject { service.update_task(asana_task, external_task) }

    let(:asana_task) { nil }
    let(:external_task) { nil }

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end
end
