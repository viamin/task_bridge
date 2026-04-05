# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GoogleTasks::Service" do
  let(:tasks_service) { instance_double(Google::Apis::TasksV1::TasksService, "authorization=": true) }
  let(:service) { GoogleTasks::Service.new(tasks_service:, authorization: {}) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }
  let(:force) { false }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced).and_return(last_sync)
    service.options = service.options.merge(force:)
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
    subject(:items_to_sync) { service.items_to_sync(only_modified_dates:) }

    let(:only_modified_dates) { false }
    let(:tasklist) { instance_double(Google::Apis::TasksV1::TaskList, id: "task-list-id", title: "My Tasks") }
    let(:tasklists_response) { double("tasklists_response", items: [tasklist]) }
    let(:external_task) { instance_double(Google::Apis::TasksV1::Task, id: "google-task-id") }
    let(:tasks_response) { instance_double(Google::Apis::TasksV1::Tasks, items: [external_task]) }
    let(:wrapped_task) { instance_double(GoogleTasks::Task, "google_task=": external_task) }

    before do
      allow(tasks_service).to receive(:list_tasklists).and_return(tasklists_response)
      allow(tasks_service).to receive(:list_tasks).with(
        "task-list-id",
        max_results: 100,
        completed_min: service.send(:completed_min_timestamp),
        updated_min: service.send(:last_sync_time)&.iso8601
      ).and_return(tasks_response)
      allow(GoogleTasks::Task).to receive(:find_or_initialize_by).with(external_id: "google-task-id").and_return(wrapped_task)
      allow(wrapped_task).to receive(:refresh_from_external!).and_return(wrapped_task)
    end

    it "hydrates tasks using the caller's partial-read setting" do
      items_to_sync

      expect(wrapped_task).to have_received(:refresh_from_external!).with(only_modified_dates: false)
      expect(items_to_sync).to eq([wrapped_task])
    end

    context "when partial reads are requested" do
      let(:only_modified_dates) { true }

      it "passes the partial-read flag through to the wrapped task" do
        items_to_sync

        expect(wrapped_task).to have_received(:refresh_from_external!).with(only_modified_dates: true)
      end
    end
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

    context "when force is enabled" do
      let(:force) { true }
      let(:task_updated_at) { nil }
      let(:last_sync) { Time.now - Chronic.parse("1 minute ago") }

      it { is_expected.to be true }
    end
  end

  describe "#add_item" do
    subject { service.add_item(external_task) }

    let(:tasklist) { instance_double(Google::Apis::TasksV1::TaskList, id: "task-list-id") }
    let(:external_task) { instance_double(Asana::Task) }
    let(:google_task_payload) { { title: "Test" } }
    let(:google_task) { instance_double(Google::Apis::TasksV1::Task, pretty_inspect: "new task") }
    let(:created_google_task) do
      instance_double(
        Google::Apis::TasksV1::Task,
        id: "google-task-id",
        self_link: "https://tasks.example/google-task-id",
        to_h: google_task_payload
      )
    end

    before do
      allow(service).to receive(:tasklist).and_return(tasklist)
      allow(GoogleTasks::Task).to receive(:from_external).with(external_task).and_return(google_task_payload)
      allow(Google::Apis::TasksV1::Task).to receive(:new).with(**google_task_payload).and_return(google_task)
      allow(tasks_service).to receive(:insert_task).with("task-list-id", google_task).and_return(created_google_task)
    end

    it "inserts the task and records the created task metadata" do
      expect(service).to receive(:update_sync_data).with(
        external_task,
        "google-task-id",
        "https://tasks.example/google-task-id"
      )

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

    context "when the remote task id is missing" do
      let(:google_task) { instance_double(Google::Apis::TasksV1::Task, id: nil, pretty_inspect: "existing task") }

      it "raises a clear error before calling the API" do
        expect(tasks_service).not_to receive(:patch_task)

        expect { subject }.to raise_error(ArgumentError, "Google task is missing an external ID")
      end
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

  describe "#tasklist" do
    let(:service_with_list) { GoogleTasks::Service.new(options: { list: "Missing" }, tasks_service:, authorization: {}) }
    let(:tasklists_response) { double("tasklists_response", items: nil) }

    before do
      allow(tasks_service).to receive(:list_tasklists).and_return(tasklists_response)
    end

    it "raises a clear error when the API returns no task lists" do
      expect { service_with_list.send(:tasklist) }.to raise_error(RuntimeError, "tasklist (Missing) not found in []")
    end
  end
end
