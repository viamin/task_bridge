# frozen_string_literal: true

require "spec_helper"

RSpec.describe TaskBridgeWeb::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: nil) }
  let(:api_key) { "test-api-key" }
  let(:options) { full_options.merge(logger: logger, pretend:, verbose:, update_ids_for_existing: false) }
  let(:pretend) { true }
  let(:verbose) { false }
  let(:service) { described_class.new(options:) }

  before do
    allow(Chamber).to receive(:dig!).with(:task_bridge_web, :api_key).and_return(api_key)
    allow(logger).to receive(:sync_data_for).with("TaskBridgeWeb").and_return({})
  end

  describe "#items_to_sync" do
    let(:task_payload) { { "id" => "123", "title" => "Example" } }

    before do
      allow(service).to receive(:fetch_tasks).and_return([task_payload])
    end

    it "wraps remote tasks in Task objects" do
      tasks = service.items_to_sync
      expect(tasks.length).to eq(1)
      expect(tasks.first).to be_a(TaskBridgeWeb::Task)
      expect(tasks.first.title).to eq("Example")
    end
  end

  describe "#add_item" do
    let(:external_task) do
      instance_double(
        "ExternalTask",
        title: "New Task",
        provider: "Omnifocus",
        completed?: false,
        sync_notes: "notes",
        due_date: Time.now,
        project: "Inbox"
      )
    end

    before do
      allow(external_task).to receive(:try).with(:project).and_return("Inbox")
    end

    context "when running in pretend mode with verbose output" do
      let(:pretend) { true }
      let(:verbose) { true }

      before do
        allow(service).to receive(:ensure_project_exists).and_return("project-1")
      end

      it "reports the simulated addition" do
        expect(service.add_item(external_task)).to eq("Would have added New Task to TaskBridge Web")
      end
    end
  end

  describe "#update_item" do
    let(:pretend) { true }
    let(:verbose) { false }
    let(:external_task) do
      instance_double(
        "ExternalTask",
        title: "Updated Task",
        provider: "Asana",
        completed?: false,
        sync_notes: "update",
        due_date: nil,
        project: nil
      )
    end
    let(:task_bridge_web_task) do
      instance_double(
        "TaskBridgeWebTask",
        id: "123",
        title: "Existing",
        url: "http://example.test/tasks/123"
      )
    end

    it "returns the pretend update message" do
      expect(service.update_item(task_bridge_web_task, external_task)).to eq("Would have updated task Updated Task in TaskBridge Web")
    end
  end

  describe "#prune" do
    let(:pretend) { false }
    let(:verbose) { true }

    before do
      allow(service).to receive(:fetch_tasks).and_return([
        { "id" => "1", "completed" => true },
        { "id" => "2", "completed" => false }
      ])
      allow(HTTParty).to receive(:delete).and_return(double(success?: true))
    end

    it "deletes completed tasks" do
      service.prune
      expect(HTTParty).to have_received(:delete).with("http://localhost:3000/api/tasks/1", anything)
    end
  end

  describe "#ensure_project_exists" do
    let(:pretend) { false }
    let(:verbose) { false }

    before do
      allow(service).to receive(:fetch_projects).and_return([{ "name" => "Inbox", "id" => "42" }])
    end

    it "returns the id of the existing project" do
      expect(service.send(:ensure_project_exists, "Inbox")).to eq("42")
    end
  end

  describe "#authenticated_options" do
    it "includes the API key header" do
      headers = service.send(:authenticated_options).fetch(:headers)
      expect(headers[:Authorization]).to eq("Bearer #{api_key}")
    end
  end
end
