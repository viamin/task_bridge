# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GoogleTasks::Service" do
  let(:tasks_service) { instance_double(Google::Apis::TasksV1::TasksService, "authorization=": true) }
  let(:service) { GoogleTasks::Service.new(tasks_service:, authorization: {}) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }

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

  describe "#item_class" do
    it "returns the wrapped sync item class" do
      expect(service.item_class).to eq(GoogleTasks::Task)
    end
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
    subject { service.add_item(external_task) }

    let(:tasklist) { instance_double(Google::Apis::TasksV1::TaskList, id: "task-list-id") }
    let(:external_task) { instance_double(Asana::Task) }
    let(:google_task_payload) { { title: "Test" } }
    let(:inserted_google_task) { instance_double(Google::Apis::TasksV1::Task, pretty_inspect: "inserted task", to_h: google_task_payload) }

    before do
      allow(service).to receive(:tasklist).and_return(tasklist)
      allow(GoogleTasks::Task).to receive(:from_external).with(external_task).and_return(google_task_payload)
      allow(Google::Apis::TasksV1::Task).to receive(:new).with(**google_task_payload).and_return(inserted_google_task)
      allow(tasks_service).to receive(:insert_task).with("task-list-id", inserted_google_task)
    end

    it "inserts the task into the configured task list" do
      expect(subject).to eq(google_task_payload)
    end
  end

  describe "#update_item" do
    subject { service.update_item(google_task, external_task) }

    let(:tasklist) { instance_double(Google::Apis::TasksV1::TaskList, id: "task-list-id") }
    let(:google_task) { instance_double(Google::Apis::TasksV1::Task, id: "google-task-id", pretty_inspect: "existing task") }
    let(:external_task) { instance_double(Asana::Task) }
    let(:updated_task_payload) { { title: "Updated title" } }
    let(:updated_google_task) { instance_double(Google::Apis::TasksV1::Task, to_h: updated_task_payload) }

    before do
      allow(service).to receive(:tasklist).and_return(tasklist)
      allow(GoogleTasks::Task).to receive(:from_external).with(external_task).and_return(updated_task_payload)
      allow(Google::Apis::TasksV1::Task).to receive(:new).with(**updated_task_payload).and_return(updated_google_task)
      allow(tasks_service).to receive(:patch_task).with("task-list-id", "google-task-id", updated_google_task)
    end

    it "updates the task using the remote task id" do
      expect(subject).to eq(updated_task_payload)
    end
  end

  describe "#patch_item" do
    subject { service.patch_item(google_task, attributes_hash) }

    let(:tasklist) { instance_double(Google::Apis::TasksV1::TaskList, id: "task-list-id") }
    let(:attributes_hash) { { notes: "patched notes" } }
    let(:updated_google_task) { instance_double(Google::Apis::TasksV1::Task, pretty_inspect: "patched task", to_h: attributes_hash) }

    before do
      allow(service).to receive(:tasklist).and_return(tasklist)
      allow(Google::Apis::TasksV1::Task).to receive(:new).with(**attributes_hash).and_return(updated_google_task)
      allow(tasks_service).to receive(:patch_task).with("task-list-id", "external-task-id", updated_google_task)
    end

    context "when given a wrapped sync item" do
      let(:google_task) { GoogleTasks::Task.new(title: "Wrapped task", external_id: "external-task-id") }

      it "patches using the sync item's external_id" do
        expect(subject).to eq(attributes_hash)
      end
    end
  end
end
