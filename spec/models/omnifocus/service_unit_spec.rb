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

    context "with metadata-only reads" do
      let(:metadata_properties) do
        {
          id_: "task-1",
          name: "Task 1",
          completed: false,
          completion_date: nil,
          modification_date: Time.current,
          note: "github_id: gh-1"
        }
      end

      before do
        allow(mock_task1).to receive(:properties_).and_return(double(get: metadata_properties))
      end

      it "hydrates from task properties instead of per-attribute AppleScript reads" do
        expect(mock_task1).not_to receive(:note)
        expect(mock_task1).not_to receive(:tags)
        expect(mock_task1).not_to receive(:tasks)

        tasks = service.items_to_sync(tags: ["TaskBridge"], inbox: false, only_modified_dates: true)

        expect(tasks.length).to eq(1)
        expect(tasks.first.external_id).to eq("task-1")
        expect(tasks.first.title).to eq("Task 1")
        expect(tasks.first.github_id).to eq("gh-1")
      end
    end

    context "when a task reference goes stale while reading the id" do
      let(:stale_id) { double("StaleTaskId") }
      let(:stale_task) { double("StaleTask", id_: stale_id) }

      before do
        allow(stale_id).to receive(:get).and_raise(make_stale_reference_error(command: "id_.get"))
        allow(service).to receive(:tagged_tasks).and_return([stale_task, mock_task1])
        allow(service).to receive(:inbox_tasks).and_return([])
      end

      it "skips the stale task and keeps syncing remaining tasks" do
        tasks = service.items_to_sync(tags: ["TaskBridge"], inbox: false)

        expect(tasks.map(&:external_id)).to eq(["task-1"])
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

  describe "#matching_items_for" do
    let(:service) { described_class.new(options:) }
    let(:properties) do
      {
        id_: "task-1",
        name: "Task 1",
        completed: false,
        completion_date: nil,
        modification_date: Time.current,
        note: "github_id: gh-1"
      }
    end
    let(:matching_task) { double("MatchingTask", properties_: double(get: properties)) }
    let(:flattened_tasks) { double("FlattenedTasks") }

    before do
      allow(mock_omnifocus_app).to receive(:flattened_tasks).and_return(flattened_tasks)
    end

    it "finds candidates by stored OmniFocus sync ID" do
      service_item = OpenStruct.new(omnifocus_id: "task-1", friendly_title: "Task 1")
      task_ref = double("TaskRef", get: matching_task)
      allow(flattened_tasks).to receive(:ID).with("task-1").and_return(task_ref)

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches.map(&:external_id)).to eq(["task-1"])
      expect(matches.first.github_id).to eq("gh-1")
    end

    it "uses persisted sync metadata for exact title matches" do
      service_item = OpenStruct.new(friendly_title: "Task 1")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["Task 1"]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      Omnifocus::Task.create!(external_id: "task-1", title: "Task 1", notes: "github_id: gh-1")

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches.map(&:title)).to eq(["Task 1"])
      expect(matches.first.github_id).to eq("gh-1")
    end

    it "uses persisted sync metadata for normalized title matches" do
      service_item = OpenStruct.new(friendly_title: "Buy milk")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["  BUY MILK  "]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      Omnifocus::Task.create!(external_id: "task-1", title: "  BUY MILK  ", notes: "github_id: gh-1")

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches.map(&:external_id)).to eq(["task-1"])
      expect(matches.first.github_id).to eq("gh-1")
    end

    it "uses metadata-backed title matches when the stored OmniFocus sync ID is stale" do
      service_item = OpenStruct.new(omnifocus_id: "stale-task", friendly_title: "Task 1")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["Task 1"]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      allow(flattened_tasks).to receive(:ID).with("stale-task").and_raise(StandardError)
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      Omnifocus::Task.create!(external_id: "task-1", title: "Task 1", notes: "github_id: gh-1")

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches.map(&:external_id)).to eq(["task-1"])
      expect(matches.first.github_id).to eq("gh-1")
    end

    it "does not return title matches when sync metadata cannot be loaded" do
      service_item = OpenStruct.new(friendly_title: "Task 1")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["Task 1"]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      expect(flattened_tasks).not_to receive(:ID)

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches).to eq([])
    end

    it "does not return title matches when cached notes are empty" do
      service_item = OpenStruct.new(friendly_title: "Task 1")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["Task 1"]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      Omnifocus::Task.create!(external_id: "task-1", title: "Task 1", notes: "")

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches).to eq([])
    end

    it "does not return title matches when cached notes lack metadata for the source provider" do
      service_item = OpenStruct.new(friendly_title: "Task 1")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["Task 1"]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      Omnifocus::Task.create!(external_id: "task-1", title: "Task 1", notes: "asana_id: asana-1")

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches).to eq([])
    end

    it "includes inbox tasks in targeted title lookup" do
      service_item = OpenStruct.new(friendly_title: "Inbox Task")
      tag_ref = double("TagRef", get: true)
      tag_tasks = double(
        "TagTasks",
        id_: double(get: []),
        name: double(get: []),
        completed: double(get: []),
        modification_date: double(get: [])
      )
      inbox_tasks = double(
        "InboxTasks",
        id_: double(get: ["task-1"]),
        name: double(get: ["Inbox Task"]),
        completed: double(get: [false]),
        modification_date: double(get: [Time.current])
      )
      allow(tag_ref).to receive(:tasks).and_return(tag_tasks)
      flattened_tags = double("FlattenedTags")
      allow(flattened_tags).to receive(:[]).with("Github").and_return(tag_ref)
      allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(flattened_tags)
      allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(inbox_tasks)
      Omnifocus::Task.create!(external_id: "task-1", title: "Inbox Task", notes: "github_id: gh-1")

      matches = service.matching_items_for([service_item], tag: "Github")

      expect(matches.map(&:external_id)).to eq(["task-1"])
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
