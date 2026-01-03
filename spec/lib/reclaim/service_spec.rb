# frozen_string_literal: true

require "spec_helper"

RSpec.describe Reclaim::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: nil) }
  let(:options) { full_options.merge(logger: logger, pretend:, verbose: false) }
  let(:pretend) { true }
  let(:service) { described_class.new(options:) }
  let(:api_key) { "test-reclaim-token" }

  before do
    allow(Chamber).to receive(:dig).with(:reclaim, :api_key).and_return(api_key)
  end

  describe "#items_to_sync" do
    before do
      allow(service).to receive(:list_tasks).and_return([{ "id" => "1", "title" => "Task 1" }])
    end

    it "wraps tasks returned from the API" do
      tasks = service.items_to_sync
      expect(tasks.length).to eq(1)
      expect(tasks.first).to be_a(Reclaim::Task)
    end
  end

  describe "#add_item" do
    let(:external_task) { task_double("New Task") }

    it "reports the pretend action" do
      expect(service.add_item(external_task)).to eq("Would have added New Task to Reclaim")
    end
  end

  describe "#update_item" do
    let(:pretend) { true }
    let(:external_task) { task_double("Updated Task") }
    let(:reclaim_task) { instance_double("ReclaimTask", id: "task-1", title: "Existing Task") }

    it "returns a pretend update message" do
      expect(service.update_item(reclaim_task, external_task)).to eq("Would have updated task Updated Task in Reclaim")
    end
  end

  describe "#authenticated_options" do
    it "uses the configured API key" do
      headers = service.send(:authenticated_options).fetch(:headers)
      expect(headers[:Authorization]).to eq("Bearer #{api_key}")
    end
  end
end

def task_double(title)
  instance_double(
    "ExternalTask",
    title: title,
    completed?: false,
    sync_notes: "notes",
    estimated_minutes: nil,
    due_date: nil,
    personal?: true,
    start_date: nil
  )
end
