# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GoogleTasks::Service" do
  let(:tasks_service) { instance_double(Google::Apis::TasksV1::TasksService, "authorization=": true) }
  let(:service) { GoogleTasks::Service.new(tasks_service:, authorization: {}) }
  let(:tasklist) { "Test" }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#sync_from_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new }

      it "syncs from primary" do
        expect(service.sync_strategies).to contain_exactly(:from_primary)
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
        let(:last_sync) { Time.now - Chronic.parse("31 minutes ago") }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("29 minutes ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("31 minutes ago") }

      it { is_expected.to be false }
    end
  end

  describe "#add_item" do
    subject { service.add_item(tasklist, external_task) }

    let(:external_task) { nil }
    let(:title) { "Test" }

    before do
      allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
    end

    it "raises an error", :no_ci do
      expect { subject }.to raise_error NoMethodError
    end
  end

  describe "#update_item" do
    subject { service.update_item(tasklist, google_task, external_task) }

    let(:tasklist) { instance_double(Google::Apis::TasksV1::TaskList, id: "task-list-id") }
    let(:google_task) { instance_double(Google::Apis::TasksV1::Task, id: "google-task-id", pretty_inspect: "existing task") }
    let(:external_task) { instance_double(Asana::Task) }
    let(:updated_task_payload) { { title: "Updated title" } }
    let(:updated_google_task) { instance_double(Google::Apis::TasksV1::Task, to_h: updated_task_payload) }

    before do
      allow(GoogleTasks::Task).to receive(:from_external).with(external_task).and_return(updated_task_payload)
      allow(Google::Apis::TasksV1::Task).to receive(:new).with(**updated_task_payload).and_return(updated_google_task)
      allow(tasks_service).to receive(:patch_task).with("task-list-id", "google-task-id", updated_google_task)
    end

    it "updates the task using the remote task id" do
      expect(subject).to eq(updated_task_payload)
    end
  end
end
