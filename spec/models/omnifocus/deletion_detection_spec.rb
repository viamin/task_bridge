# frozen_string_literal: true

require "rails_helper"

# OmniFocus side of deletion detection (#220): absence from the tagged/inbox
# query must be verified by direct ID lookup, and AppleScript/web lookup
# failures must be handled separately from task nonexistence.
RSpec.describe Omnifocus::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: Time.current - 1.hour) }
  let(:mock_omnifocus_app) { double("OmnifocusDocument") }

  before do
    mock_app_wrapper = double("AppWrapper", by_name: double(default_document: mock_omnifocus_app))
    allow(Appscript).to receive(:app).and_return(mock_app_wrapper)
  end

  describe "#verify_missing_item" do
    subject(:finding) { service.verify_missing_item(item) }

    let(:service) { described_class.new(options:) }
    let(:item) { Omnifocus::Task.new(external_id: "of-123", source_service_name: "Omnifocus") }

    context "when the task still exists" do
      it "reports no_longer_matches_query with high confidence" do
        task_ref = double("TaskRef", get: double("Task"))
        flattened = double("FlattenedTasks", find_by_id: task_ref)
        allow(mock_omnifocus_app).to receive(:flattened_tasks).and_return(flattened)

        expect(finding.state).to eq("no_longer_matches_query")
        expect(finding.confidence).to eq("high")
      end
    end

    context "when the web lookup returns no task" do
      it "reports source_deleted" do
        flattened = double("FlattenedTasks", find_by_id: nil)
        allow(mock_omnifocus_app).to receive(:flattened_tasks).and_return(flattened)

        expect(finding.state).to eq("source_deleted")
      end
    end

    context "when the AppleScript reference is stale (task does not exist)" do
      it "reports source_deleted" do
        task_ref = double("TaskRef")
        allow(task_ref).to receive(:get).and_raise(make_stale_reference_error)
        flattened = double("FlattenedTasks")
        allow(flattened).to receive(:ID).with("of-123").and_return(task_ref)
        allow(mock_omnifocus_app).to receive(:flattened_tasks).and_return(flattened)

        expect(finding.state).to eq("source_deleted")
      end
    end

    context "when the app is unreachable" do
      it "returns no finding instead of a false deletion" do
        task_ref = double("TaskRef")
        allow(task_ref).to receive(:get).and_raise(make_app_not_running_error)
        flattened = double("FlattenedTasks")
        allow(flattened).to receive(:ID).with("of-123").and_return(task_ref)
        allow(mock_omnifocus_app).to receive(:flattened_tasks).and_return(flattened)

        expect(finding).to be_nil
      end
    end

    context "when the connection is invalid" do
      it "returns no finding instead of a false deletion" do
        task_ref = double("TaskRef")
        allow(task_ref).to receive(:get).and_raise(make_connection_invalid_error)
        flattened = double("FlattenedTasks")
        allow(flattened).to receive(:ID).with("of-123").and_return(task_ref)
        allow(mock_omnifocus_app).to receive(:flattened_tasks).and_return(flattened)

        expect(finding).to be_nil
      end
    end
  end

  describe "#deletion_detection_scope_available?" do
    let(:service) { described_class.new(options: options.merge(tags: %w[TaskBridge Work])) }

    it "is available when every configured tag resolves" do
      allow(service).to receive(:tag).with("TaskBridge").and_return(double("TagRef"))
      allow(service).to receive(:tag).with("Work").and_return(double("TagRef"))

      expect(service.deletion_detection_scope_available?).to be(true)
    end

    it "is unavailable when a configured tag is missing" do
      allow(service).to receive(:tag).with("TaskBridge").and_return(nil)
      allow(service).to receive(:tag).with("Work").and_return(double("TagRef"))

      expect(service.deletion_detection_scope_available?).to be(false)
    end
  end

  describe "#items_to_sync canonical scope gate" do
    let(:service) { described_class.new(options: options.merge(tags: %w[TaskBridge])) }

    before do
      allow(service).to receive(:authorized).and_return(true)
      allow(service).to receive(:tagged_tasks).and_return([])
      allow(service).to receive(:inbox_tasks).and_return([])
      allow(service).to receive(:deletion_detection_scope_available?).and_return(true)
    end

    it "records disappearances for the canonical tag scope" do
      expect(service).to receive(:record_source_disappearances!).with([], only_modified_dates: false)

      service.items_to_sync(tags: %w[TaskBridge])
    end

    it "does not record disappearances for per-service tag scopes" do
      expect(service).not_to receive(:record_source_disappearances!)

      service.items_to_sync(tags: %w[Github])
    end

    it "does not detect on partial fetches (only_modified_dates)" do
      expect(service).to receive(:record_source_disappearances!).with([], only_modified_dates: true).and_call_original

      service.items_to_sync(tags: %w[TaskBridge], only_modified_dates: true)

      expect(OutboxEntry.count).to eq(0)
    end
  end
end
