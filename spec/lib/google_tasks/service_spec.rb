# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GoogleTasks::Service" do
  let(:service)   { GoogleTasks::Service.new(options:) }
  let(:tasklist)  { "Test" }
  let(:options)   { { logger: } }
  let(:logger)    { double(StructuredLogger) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#sync_from_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new(options: {}) }

      it "responds to #sync_from_primary", :no_ci do
        expect(service).to be_respond_to(:sync_from_primary)
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

      context "when last sync was less than min_sync_interval", :no_ci do
        let(:last_sync) { Time.now - Chronic.parse("29 minutes ago") }

        it { is_expected.to be false }
      end

      context "when last sync was more than min_sync_interval", :no_ci do
        let(:last_sync) { Time.now - Chronic.parse("31 minutes ago") }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval", :no_ci do
      let(:task_updated_at) { Chronic.parse("29 minutes ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval", :no_ci do
      let(:task_updated_at) { Chronic.parse("31 minutes ago") }

      it { is_expected.to be false }
    end
  end

  describe "#add_item" do
    subject { service.add_item(tasklist, external_task, parent_task_gid) }

    let(:external_task) { nil }
    let(:parent_task_gid) { nil }
    let(:title) { "Test" }

    before do
      allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
    end

    it "raises an error", :no_ci do
      expect { subject }.to raise_error NoMethodError
    end

    context "with Omnifocus task" do
      let(:external_task) { Omnifocus::Service.new.items_to_sync(projects: "TaskBridge:Test").first }

      context "with a regular task" do
      end

      context "with a task with a subtask" do
      end

      context "with a task in a section" do
      end
    end
  end

  describe "#update_item" do
    subject { service.update_item(tasklist, google_task, external_task, options) }

    let(:google_task) { nil }
    let(:external_task) { nil }

    it "raises an error", :no_ci do
      expect { subject }.to raise_error NoMethodError
    end
  end
end
