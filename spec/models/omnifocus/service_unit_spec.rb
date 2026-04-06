# frozen_string_literal: true

require "rails_helper"

# Fast unit tests for Omnifocus::Service with mocked AppleScript calls.
# These tests don't require OmniFocus to be running.
# For integration tests that test real OmniFocus interaction, see service_spec.rb
RSpec.describe Omnifocus::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger) }
  let(:mock_omnifocus_app) { double("OmnifocusDocument") }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(Time.now - 1.hour)
    # Mock the Appscript initialization
    mock_app_wrapper = double("AppWrapper", by_name: double(default_document: mock_omnifocus_app))
    allow(Appscript).to receive(:app).and_return(mock_app_wrapper)
  end

  describe "#initialize" do
    context "when OmniFocus is available" do
      it "sets authorized to true" do
        service = described_class.new(options:)
        expect(service.authorized).to be true
      end

      it "stores the omnifocus_app reference" do
        service = described_class.new(options:)
        expect(service.omnifocus_app).to eq(mock_omnifocus_app)
      end
    end

    context "when OmniFocus is not available" do
      before do
        allow(Appscript).to receive(:app).and_raise(StandardError.new("App not found"))
      end

      it "sets authorized to false" do
        service = described_class.new(options: options.merge(quiet: true))
        expect(service.authorized).to be false
      end

      it "sets omnifocus_app to nil" do
        service = described_class.new(options: options.merge(quiet: true))
        expect(service.omnifocus_app).to be_nil
      end
    end
  end

  describe "#friendly_name" do
    let(:service) { described_class.new(options:) }

    it "returns 'Omnifocus'" do
      expect(service.friendly_name).to eq("Omnifocus")
    end
  end

  describe "#sync_strategies" do
    let(:service) { described_class.new(options:) }

    it "returns [:from_primary]" do
      expect(service.sync_strategies).to eq([:from_primary])
    end
  end

  describe "#item_class" do
    let(:service) { described_class.new(options:) }

    it "returns Omnifocus::Task" do
      expect(service.item_class).to eq(Omnifocus::Task)
    end
  end

  describe "#items_to_sync" do
    let(:service) { described_class.new(options:) }
    let(:mock_task1) do
      double("OmnifocusTask1",
             id_: double(get: "task-1"),
             name: double(get: "Task 1"),
             completed: double(get: false),
             note: double(get: ""),
             containing_project: double(get: :missing_value),
             tags: double(get: []),
             tasks: double(get: []),
             modification_date: double(get: Time.now))
    end
    let(:mock_task2) do
      double("OmnifocusTask2",
             id_: double(get: "task-2"),
             name: double(get: "Task 2"),
             completed: double(get: false),
             note: double(get: ""),
             containing_project: double(get: :missing_value),
             tags: double(get: []),
             tasks: double(get: []),
             modification_date: double(get: Time.now))
    end

    before do
      # Mock tagged_tasks to return our mock tasks
      allow(service).to receive(:tagged_tasks).and_return([mock_task1])
      allow(service).to receive(:inbox_tasks).and_return([mock_task2])
    end

    context "with tags" do
      it "returns tasks with matching tags" do
        tasks = service.items_to_sync(tags: ["TaskBridge"], inbox: false)
        expect(tasks.length).to eq(1)
        expect(tasks.first.title).to eq("Task 1")
      end
    end

    context "with inbox: true" do
      it "includes inbox tasks" do
        tasks = service.items_to_sync(tags: ["TaskBridge"], inbox: true)
        expect(tasks.length).to eq(2)
      end
    end

    context "with inbox: false" do
      it "excludes inbox tasks" do
        tasks = service.items_to_sync(tags: ["TaskBridge"], inbox: false)
        expect(tasks.length).to eq(1)
      end
    end

    context "with sub-items" do
      let(:mock_parent_task) do
        double("ParentTask",
               id_: double(get: "parent-1"),
               name: double(get: "Parent Task"),
               completed: double(get: false),
               note: double(get: ""),
               containing_project: double(get: :missing_value),
               tags: double(get: []),
               tasks: double(get: [mock_subtask]),
               modification_date: double(get: Time.now))
      end
      let(:mock_subtask) do
        double("Subtask",
               id_: double(get: "subtask-1"),
               name: double(get: "Subtask"),
               completed: double(get: false),
               note: double(get: ""),
               containing_project: double(get: :missing_value),
               tags: double(get: []),
               tasks: double(get: []),
               modification_date: double(get: Time.now))
      end

      before do
        allow(service).to receive(:tagged_tasks).and_return([mock_parent_task, mock_subtask])
        allow(service).to receive(:inbox_tasks).and_return([])
      end

      it "removes sub-items from the list to avoid duplicates" do
        tasks = service.items_to_sync(tags: ["TaskBridge"], inbox: false)
        # Should only have parent, subtask should be filtered out
        expect(tasks.length).to eq(1)
        expect(tasks.first.title).to eq("Parent Task")
      end
    end
  end

  describe "#tagged_tasks" do
    let(:service) { described_class.new(options:) }
    let(:mock_tag) { double("Tag", name: double(get: "TaskBridge")) }
    let(:mock_task) { double("Task", tasks: double(get: [])) }
    let(:mock_flattened_tags) { double("FlattenedTags") }

    before do
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(mock_flattened_tags)
      # New implementation uses [] to look up tags by name directly
      allow(mock_flattened_tags).to receive(:[]).with("TaskBridge").and_return(mock_tag)
      # For non-existent tags, [] returns a reference but .get raises an error
      mock_nonexistent_tag = double("NonExistentTagRef")
      allow(mock_flattened_tags).to receive(:[]).with("NonExistentTag").and_return(mock_nonexistent_tag)
      allow(mock_nonexistent_tag).to receive(:get).and_raise(StandardError.new("Tag not found"))
      allow(mock_tag).to receive(:get).and_return(mock_tag)
      allow(mock_tag).to receive(:tasks).and_return(double(get: [mock_task]))
    end

    it "returns tasks that have matching tags" do
      tasks = service.tagged_tasks(["TaskBridge"])
      expect(tasks).to include(mock_task)
    end

    it "returns empty array when no tags match" do
      tasks = service.tagged_tasks(["NonExistentTag"])
      expect(tasks).to eq([])
    end
  end

  describe "#inbox_tasks" do
    let(:service) { described_class.new(options:) }
    let(:mock_inbox_task) { double("InboxTask", tasks: double(get: [])) }

    before do
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(double(get: [mock_inbox_task]))
    end

    it "returns tasks from the inbox" do
      tasks = service.send(:inbox_tasks)
      expect(tasks).to include(mock_inbox_task)
    end
  end

  describe "#skip_create?" do
    let(:service) { described_class.new(options:) }

    it "returns true for completed items" do
      completed_item = double("CompletedItem", completed?: true)
      expect(service.skip_create?(completed_item)).to be true
    end

    it "returns false for incomplete items" do
      incomplete_item = double("IncompleteItem", completed?: false)
      expect(service.skip_create?(incomplete_item)).to be false
    end
  end

  describe "#update_item" do
    let(:service) { described_class.new(options: options.merge(max_age: "1 day", max_age_timestamp: 1.day.ago)) }
    let(:omnifocus_task) { instance_double("Omnifocus::Task", incomplete?: true) }
    let(:external_task) do
      instance_double(
        Base::SyncItem,
        title: "Stale task",
        completed?: false,
        last_modified: 2.days.ago,
        updated_at: Time.current
      )
    end

    it "uses last_modified for max-age filtering" do
      expect(service.update_item(omnifocus_task, external_task)).to eq(
        "Last modified more than 1 day ago - skipping Stale task"
      )
    end
  end

  describe "#add_item" do
    let(:service) { described_class.new(options:) }
    let(:mock_new_task) { double("OmnifocusNativeTask", id_: double(get: "of-123")) }
    let(:wrapped_task) { instance_double("Omnifocus::Task") }
    let(:sub_item) do
      double(
        "SubItem",
        title: "Sub task",
        completed?: false
      )
    end
    let(:external_task) do
      double(
        "ExternalTask",
        title: "Task with sub-items",
        sub_item_count: 1,
        sub_items: [sub_item],
        project: nil
      )
    end
    let(:tag) { double("Tag") }

    before do
      allow(mock_omnifocus_app).to receive(:make).and_return(mock_new_task)
      allow(service).to receive(:tags).with(external_task).and_return([tag])
      allow(service).to receive(:tag).with(tag).and_return(tag)
      allow(service).to receive(:update_sync_data).and_return(nil)
      allow(service).to receive(:add_tag)
      allow(service).to receive(:handle_sub_items).with(wrapped_task, external_task)
      allow(Omnifocus::Task).to receive(:new).with(omnifocus_task: mock_new_task).and_return(wrapped_task)
      allow(wrapped_task).to receive(:sub_items).and_return([])
      allow(wrapped_task).to receive(:refresh_from_external!)
    end

    it "hydrates the created task before syncing sub-items" do
      expect(wrapped_task).to receive(:refresh_from_external!).ordered
      expect(service).to receive(:handle_sub_items).with(wrapped_task, external_task).ordered

      service.add_item(external_task)
    end
  end
end
