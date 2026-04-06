# frozen_string_literal: true

require "rails_helper"

RSpec.describe Asana::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}) }
  let(:base_options) do
    full_options.merge(
      logger: logger,
      sync_started_at: "2024-01-01 09:00AM",
      quiet: true,
      debug: false,
      pretend: false
    )
  end
  let(:options) { base_options }

  subject(:service) { described_class.new(options: options) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(Time.now - 1.hour)
  end

  describe "#items_to_sync" do
    let(:parent_task_data) do
      JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))).merge(
        "gid" => "parent-gid",
        "name" => "Parent Task",
        "num_subtasks" => 1
      )
    end
    let(:sub_task_data) do
      parent_task_data.merge(
        "gid" => "subtask-gid",
        "name" => "Sub Task",
        "num_subtasks" => 0,
        "notes" => ""
      )
    end
    let(:parent_task) { Asana::Task.new(asana_task: parent_task_data, options: options) }
    let(:sub_task) { Asana::Task.new(asana_task: sub_task_data, options: options) }

    before do
      allow(service).to receive(:list_projects).and_return([{ "gid" => "project-gid" }])
      allow(service).to receive(:list_project_tasks).with("project-gid", only_modified_dates: false).and_return([parent_task_data, sub_task_data])
      allow(service).to receive(:list_task_sub_items).with("parent-gid", only_modified_dates: false).and_return([sub_task_data])
      allow(Asana::Task).to receive(:find_or_initialize_by).with(external_id: "parent-gid").and_return(parent_task)
      allow(Asana::Task).to receive(:find_or_initialize_by).with(external_id: "subtask-gid").and_return(sub_task)
    end

    it "hydrates loaded subtasks before matching and deduping them" do
      tasks = service.items_to_sync

      expect(tasks.map(&:external_id)).to eq(["parent-gid"])
      expect(tasks.first.sub_items.map(&:external_id)).to eq(["subtask-gid"])
      expect(tasks.first.sub_items.map(&:title)).to eq(["Sub Task"])
    end

    it "accepts unused base-service keywords when Asana is the primary service" do
      expect do
        service.items_to_sync(tags: ["TaskBridge"], inbox: true)
      end.not_to raise_error
    end

    it "threads only_modified_dates through subtask reads" do
      expect(service).to receive(:list_project_tasks).with("project-gid", only_modified_dates: true).and_return([parent_task_data, sub_task_data])
      expect(service).to receive(:list_task_sub_items).with("parent-gid", only_modified_dates: true).and_return([sub_task_data])

      service.items_to_sync(only_modified_dates: true)
    end
  end

  describe "persisted hydration" do
    let(:persisted_task_data) do
      JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))).merge(
        "gid" => "persisted-gid",
        "name" => "Persisted Parent Task",
        "modified_at" => "2024-04-03T12:00:00Z",
        "notes" => "omnifocus_id: of-123\nomnifocus_url: omnifocus:///task/of-123",
        "num_subtasks" => 0
      )
    end

    before do
      allow(service).to receive(:list_projects).and_return([{ "gid" => "project-gid" }])
      allow(service).to receive(:list_project_tasks).with("project-gid", only_modified_dates: false).and_return([persisted_task_data])
      allow(service).to receive(:list_task_sub_items)
    end

    it "persists hydrated sync state for future runs" do
      service.items_to_sync

      item = Asana::Task.find_by!(external_id: "persisted-gid")

      expect(item.title).to eq("Persisted Parent Task")
      expect(item.last_modified).to eq(Time.zone.parse("2024-04-03T12:00:00Z"))
      expect(item.notes).to eq(persisted_task_data["notes"])
      expect(item.omnifocus_id).to eq("of-123")
    end
  end
end
