# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/omnifocus_error_helpers"

# Integration tests for OmniFocus AppleScript error handling.
# These tests verify proper handling of macOS AppleScript errors:
#   - OSERROR -600: "Application isn't running"
#   - OSERROR -609: "Connection is invalid"
#
# Tests marked with :no_ci require OmniFocus to be installed on macOS
# and are excluded from CI via `--tag ~no_ci`.
RSpec.describe "Omnifocus::Service AppleScript Error Handling", :full_options do
  let(:service) { Omnifocus::Service.new(options:) }
  let(:logger) { double(StructuredLogger) }
  let(:last_sync) { Time.now - 20.minutes }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "initialization error handling" do
    context "when OmniFocus is not installed", :no_ci do
      before do
        allow(Appscript).to receive(:app).and_raise(make_app_not_found_error)
      end

      it "sets authorized to false" do
        service = Omnifocus::Service.new(options: options.merge(quiet: true))
        expect(service.authorized).to be false
      end

      it "sets omnifocus_app to nil" do
        service = Omnifocus::Service.new(options: options.merge(quiet: true))
        expect(service.omnifocus_app).to be_nil
      end
    end

    context "when OmniFocus is not running (OSERROR -600)", :no_ci do
      before do
        mock_app = double("Appscript::Application")
        allow(Appscript).to receive(:app).and_return(double(by_name: mock_app))
        allow(mock_app).to receive(:default_document).and_raise(make_app_not_running_error)
      end

      it "sets authorized to false" do
        service = Omnifocus::Service.new(options: options.merge(quiet: true))
        expect(service.authorized).to be false
      end

      it "sets omnifocus_app to nil" do
        service = Omnifocus::Service.new(options: options.merge(quiet: true))
        expect(service.omnifocus_app).to be_nil
      end
    end

    context "when connection becomes invalid (OSERROR -609)", :no_ci do
      before do
        mock_app = double("Appscript::Application")
        allow(Appscript).to receive(:app).and_return(double(by_name: mock_app))
        allow(mock_app).to receive(:default_document).and_raise(make_connection_invalid_error)
      end

      it "sets authorized to false" do
        service = Omnifocus::Service.new(options: options.merge(quiet: true))
        expect(service.authorized).to be false
      end
    end
  end

  describe "#items_to_sync error handling", :no_ci do
    let(:mock_omnifocus_app) { double("OmnifocusDocument") }

    before do
      allow(service).to receive(:omnifocus_app).and_return(mock_omnifocus_app)
    end

    context "when flattened_tags[tag].get raises -600 error" do
      before do
        mock_tags = double("flattened_tags")
        mock_tag_ref = double("tag_ref")
        allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(mock_tags)
        # New implementation uses [] to look up tags by name
        allow(mock_tags).to receive(:[]).with("TaskBridge").and_return(mock_tag_ref)
        allow(mock_tag_ref).to receive(:get).and_raise(make_app_not_running_error(command: "flattened_tags.get"))
      end

      it "treats the tag as not found and returns empty array" do
        # The new implementation catches errors during tag lookup and treats them as non-existent tags
        expect(service.tagged_tasks(["TaskBridge"])).to eq([])
      end
    end

    context "when inbox_tasks.get raises -609 error" do
      before do
        mock_inbox = double("inbox_tasks")
        allow(mock_omnifocus_app).to receive(:inbox_tasks).and_return(mock_inbox)
        allow(mock_inbox).to receive(:get).and_raise(make_connection_invalid_error(command: "inbox_tasks.get"))
      end

      it "raises an Appscript::CommandError" do
        expect { service.inbox_tasks }.to raise_error(Appscript::CommandError)
      end
    end
  end

  describe "#add_item error handling", :no_ci do
    let(:mock_omnifocus_app) { double("OmnifocusDocument") }
    let(:external_task) do
      double("ExternalTask",
        title: "Test Task",
        friendly_title: "Test Task",
        notes: "Test notes",
        tags: [],
        project: nil,
        sub_items: [],
        sub_item_count: 0,
        try: nil)
    end

    before do
      allow(service).to receive(:omnifocus_app).and_return(mock_omnifocus_app)
      allow(service).to receive(:tags).and_return([])
      allow(external_task).to receive(:try).with(:friendly_title).and_return("Test Task")
      allow(external_task).to receive(:try).with(:title).and_return("Test Task")
      allow(external_task).to receive(:try).with(:external_sync_notes).and_return(nil)
      allow(external_task).to receive(:try).with(:notes).and_return("Test notes")
      allow(external_task).to receive(:try).with(:flagged).and_return(nil)
      allow(external_task).to receive(:try).with(:completed_at).and_return(nil)
      allow(external_task).to receive(:try).with(:completed_on).and_return(nil)
      allow(external_task).to receive(:try).with(:start_at).and_return(nil)
      allow(external_task).to receive(:try).with(:start_date).and_return(nil)
      allow(external_task).to receive(:try).with(:due_at).and_return(nil)
      allow(external_task).to receive(:try).with(:due_date).and_return(nil)
      allow(external_task).to receive(:try).with(:estimated_minutes).and_return(nil)
    end

    context "when creating a task raises -600 error" do
      before do
        allow(mock_omnifocus_app).to receive(:make).and_raise(make_app_not_running_error(command: "make"))
      end

      it "raises an Appscript::CommandError" do
        expect { service.add_item(external_task) }.to raise_error(Appscript::CommandError)
      end
    end

    context "when getting the new task ID raises -609 error" do
      let(:mock_new_task) { double("NewTask") }
      let(:mock_id) { double("id_") }

      before do
        allow(mock_omnifocus_app).to receive(:make).and_return(mock_new_task)
        allow(mock_new_task).to receive(:id_).and_return(mock_id)
        allow(mock_id).to receive(:get).and_raise(make_connection_invalid_error(command: "id_.get"))
      end

      it "raises an Appscript::CommandError" do
        expect { service.add_item(external_task) }.to raise_error(Appscript::CommandError)
      end
    end
  end

  describe "#update_item error handling", :no_ci do
    let(:mock_omnifocus_task) do
      double("OmnifocusTask",
        title: "Test Task",
        incomplete?: true,
        tags: [],
        id_: double("id_", get: "test-id-123"))
    end
    let(:external_task) do
      double("ExternalTask",
        title: "Test Task",
        completed?: true,
        updated_at: Time.now,
        tags: [],
        project: nil,
        sub_items: [],
        sub_item_count: 0)
    end

    before do
      allow(external_task).to receive(:respond_to?).with(:sub_item_count).and_return(true)
      allow(external_task).to receive(:try).with(:project).and_return(nil)
    end

    context "when mark_complete raises -600 error" do
      before do
        allow(mock_omnifocus_task).to receive(:mark_complete).and_raise(make_app_not_running_error(command: "mark_complete"))
      end

      it "raises an Appscript::CommandError" do
        expect { service.update_item(mock_omnifocus_task, external_task) }.to raise_error(Appscript::CommandError)
      end
    end

    context "when adding tags raises -609 error" do
      let(:mock_omnifocus_app) { double("OmnifocusDocument") }
      let(:mock_tag) { double("Tag", name: double(get: "TaskBridge")) }
      let(:mock_target_task) { double("TargetTask") }
      let(:mock_tags_collection) { double("TagsCollection") }

      before do
        allow(service).to receive(:omnifocus_app).and_return(mock_omnifocus_app)

        # Mock the target_task name and tags lookup
        allow(mock_target_task).to receive(:name).and_return(double(get: "Test Task"))
        allow(mock_target_task).to receive(:tags).and_return(mock_tags_collection)
        allow(mock_tags_collection).to receive(:get).and_return([])

        # The actual error when adding the tag
        allow(mock_omnifocus_app).to receive(:add).and_raise(make_connection_invalid_error(command: "add"))
      end

      it "raises an Appscript::CommandError when adding a tag" do
        # Test the add_tag method directly since update_item requires too much mocking
        expect { service.send(:add_tag, task: mock_target_task, tag: mock_tag) }.to raise_error(Appscript::CommandError)
      end
    end
  end
end

# Integration tests for Omnifocus::Task AppleScript error handling
RSpec.describe "Omnifocus::Task AppleScript Error Handling", :full_options do
  let(:service) { Omnifocus::Service.new(options:) }
  let(:logger) { double(StructuredLogger) }
  let(:last_sync) { Time.now - 20.minutes }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#original_task error handling", :no_ci do
    let(:task_id) { "test-task-id" }
    let(:task_properties) do
      OpenStruct.new({
        id_: task_id,
        name: "Test Task",
        completed: false,
        note: "",
        containing_project: nil,
        tags: [],
        tasks: []
      })
    end
    let(:task) { Omnifocus::Task.new(omnifocus_task: task_properties, options:) }

    context "when service.omnifocus_app.flattened_tags raises -609 error" do
      let(:mock_omnifocus_app) { double("OmnifocusDocument") }
      let(:mock_flattened_tags) { double("flattened_tags") }
      let(:mock_tasks_ref) { double("tasks_ref") }

      before do
        allow(task).to receive(:service).and_return(service)
        allow(service).to receive(:omnifocus_app).and_return(mock_omnifocus_app)
        allow(mock_omnifocus_app).to receive(:flattened_tags).and_return(mock_flattened_tags)
        allow(mock_flattened_tags).to receive(:[]).and_return(mock_tasks_ref)
        allow(mock_tasks_ref).to receive(:tasks).and_return(double(get: []))
        # Raise error when trying to get tasks
        allow(mock_tasks_ref).to receive(:tasks).and_raise(make_connection_invalid_error(command: "tasks.get"))
      end

      it "raises an Appscript::CommandError when searching for original task" do
        expect { task.original_task }.to raise_error(Appscript::CommandError)
      end
    end
  end

  describe "#mark_complete error handling", :no_ci do
    let(:task_properties) do
      OpenStruct.new({
        id_: "test-task-id",
        name: "Test Task",
        completed: false,
        note: "",
        containing_project: nil,
        tags: [],
        tasks: []
      })
    end
    let(:task) { Omnifocus::Task.new(omnifocus_task: task_properties, options:) }
    let(:mock_original_task) { double("OriginalTask") }

    context "when mark_complete AppleScript command fails with -600" do
      before do
        allow(task).to receive(:original_task).and_return(mock_original_task)
        allow(mock_original_task).to receive(:mark_complete).and_raise(make_app_not_running_error(command: "mark_complete"))
      end

      it "raises an Appscript::CommandError" do
        expect { task.mark_complete }.to raise_error(Appscript::CommandError)
      end
    end
  end

  describe "#containers error handling", :no_ci do
    let(:task_properties) do
      OpenStruct.new({
        id_: "test-task-id",
        name: "Test Task",
        completed: false,
        note: "",
        containing_project: nil,
        tags: [],
        tasks: []
      })
    end
    let(:task) { Omnifocus::Task.new(omnifocus_task: task_properties, options:) }
    let(:mock_original_task) { double("OriginalTask") }
    let(:mock_container_ref) { double("container_ref") }

    context "when container.get raises -609 error" do
      before do
        allow(task).to receive(:original_task).and_return(mock_original_task)
        allow(mock_original_task).to receive(:container).and_return(mock_container_ref)
        allow(mock_container_ref).to receive(:get).and_raise(make_connection_invalid_error(command: "container.get"))
      end

      it "raises an Appscript::CommandError" do
        expect { task.containers }.to raise_error(Appscript::CommandError)
      end
    end
  end

  describe "#update_attributes error handling", :no_ci do
    let(:task_properties) do
      OpenStruct.new({
        id_: "test-task-id",
        name: "Test Task",
        completed: false,
        note: "",
        containing_project: nil,
        tags: [],
        tasks: []
      })
    end
    let(:task) { Omnifocus::Task.new(omnifocus_task: task_properties, options:) }
    let(:mock_original_task) { double("OriginalTask") }
    let(:mock_name_attribute) { double("name_attribute") }

    context "when setting attribute raises -600 error" do
      before do
        allow(task).to receive(:original_task).and_return(mock_original_task)
        allow(mock_original_task).to receive(:name).and_return(mock_name_attribute)
        allow(mock_name_attribute).to receive(:set).and_raise(make_app_not_running_error(command: "name.set"))
      end

      it "raises an Appscript::CommandError" do
        expect { task.update_attributes({title: "New Title"}) }.to raise_error(Appscript::CommandError)
      end
    end
  end
end
