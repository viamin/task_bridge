# frozen_string_literal: true

require "spec_helper"

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

  describe "#update_item adding sync IDs on title match" do
    let(:asana_task_json) { JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))) }
    let(:asana_task) { Asana::Task.new(asana_task: asana_task_json, options: options) }
    # Use the same project as the fixture to avoid triggering memberships_for_task API calls
    let(:external_task_project) { "Pets:Bucky" }
    let(:external_task) do
      double(
        "ExternalTask",
        completed?: false,
        title: "Test Task",
        project: external_task_project,
        sync_notes: "notes",
        sub_item_count: 0,
        due_date: nil,
        flagged: false
      )
    end
    let(:httparty_success_mock) do
      instance_double(HTTParty::Response, success?: true, body: '{"data": {}}')
    end

    before do
      allow(HTTParty).to receive(:put).and_return(httparty_success_mock)
      allow(external_task).to receive(:respond_to?).with(:sub_item_count).and_return(true)
    end

    context "when the item was matched by title (external task has no sync ID)" do
      let(:options) { base_options.merge(update_ids_for_existing: false) }

      before do
        allow(external_task).to receive(:try).with(:asana_id).and_return(nil)
      end

      it "adds sync ID to graduate from title matching to ID matching" do
        expect(service).to receive(:update_sync_data).with(external_task, asana_task.id, asana_task.url)

        service.update_item(asana_task, external_task)
      end
    end

    context "when the item was matched by ID (external task already has sync ID)" do
      let(:options) { base_options.merge(update_ids_for_existing: false) }

      before do
        allow(external_task).to receive(:try).with(:asana_id).and_return(asana_task.id)
      end

      it "does not update sync data since items are already linked" do
        expect(service).not_to receive(:update_sync_data)

        service.update_item(asana_task, external_task)
      end
    end

    context "when update_ids_for_existing option is enabled" do
      let(:options) { base_options.merge(update_ids_for_existing: true) }

      before do
        allow(external_task).to receive(:try).with(:asana_id).and_return(asana_task.id)
      end

      it "always updates sync data regardless of existing sync ID" do
        expect(service).to receive(:update_sync_data).with(external_task, asana_task.id, asana_task.url)

        service.update_item(asana_task, external_task)
      end
    end

    context "when running in pretend mode" do
      let(:options) { base_options.merge(pretend: true) }

      before do
        allow(external_task).to receive(:try).with(:asana_id).and_return(nil)
      end

      it "does not update sync data" do
        expect(service).not_to receive(:update_sync_data)

        result = service.update_item(asana_task, external_task)

        expect(result).to include("Would have updated")
      end
    end

    context "when API call fails" do
      let(:httparty_failure_mock) do
        instance_double(HTTParty::Response, success?: false, code: 400, body: '{"error": "Bad request"}')
      end

      before do
        allow(HTTParty).to receive(:put).and_return(httparty_failure_mock)
        allow(external_task).to receive(:try).with(:asana_id).and_return(nil)
      end

      it "does not update sync data on failure" do
        expect(service).not_to receive(:update_sync_data)

        service.update_item(asana_task, external_task)
      end
    end
  end

  describe "#update_item project change handling" do
    let(:asana_task_json) { JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))) }
    let(:asana_task) { Asana::Task.new(asana_task: asana_task_json, options: options) }
    let(:httparty_success_mock) do
      instance_double(HTTParty::Response, success?: true, body: '{"data": {}}')
    end
    let(:new_section_gid) { "section-gid-456" }
    let(:new_project_gid) { "project-gid-789" }

    before do
      allow(HTTParty).to receive(:put).and_return(httparty_success_mock)
    end

    context "when external task has a different project than asana task" do
      let(:external_task) do
        double(
          "ExternalTask",
          completed?: false,
          title: "Test Task",
          project: "Different Project",
          sync_notes: "notes",
          sub_item_count: 0,
          due_date: nil,
          flagged: false
        )
      end

      before do
        # Allow respond_to? for any argument (RSpec checks for argument matchers)
        allow(external_task).to receive(:respond_to?) { |method| method == :sub_item_count }
        allow(external_task).to receive(:try).with(:asana_id).and_return(asana_task.id)
        # Stub memberships_for_task to return project/section data
        allow(service).to receive(:memberships_for_task).with(external_task).and_return({
          project: new_project_gid,
          section: new_section_gid
        })
        allow(service).to receive(:section_identifier_for).with(external_task).and_return(new_section_gid)
      end

      it "adds the task to the new project via API" do
        allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
        allow(service).to receive(:move_task_to_section).and_return(nil)

        expect(HTTParty).to receive(:post).with(
          "https://app.asana.com/api/1.0/tasks/#{asana_task.id}/addProject",
          hash_including(:body)
        )

        service.update_item(asana_task, external_task)
      end

      it "moves the task to the correct section after changing project" do
        allow(HTTParty).to receive(:post).and_return(httparty_success_mock)

        expect(service).to receive(:move_task_to_section).with(new_section_gid, asana_task.id)

        service.update_item(asana_task, external_task)
      end

      context "when addProject API call fails" do
        let(:httparty_project_failure_mock) do
          instance_double(HTTParty::Response, success?: false, code: 400, body: '{"error": "Project not found"}')
        end

        before do
          allow(HTTParty).to receive(:post).and_return(httparty_project_failure_mock)
        end

        it "returns a failure message and does not move to section" do
          expect(service).not_to receive(:move_task_to_section)

          result = service.update_item(asana_task, external_task)

          expect(result).to include("Failed to update Asana task")
        end
      end

      context "when move_task_to_section returns an error" do
        before do
          allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
          allow(service).to receive(:move_task_to_section).and_return("Failed to move task to section")
        end

        it "returns the section move error" do
          result = service.update_item(asana_task, external_task)

          expect(result).to eq("Failed to move task to section")
        end
      end
    end

    context "when external task has no project" do
      let(:external_task) do
        double(
          "ExternalTask",
          completed?: false,
          title: "Test Task",
          project: nil,
          sync_notes: "notes",
          sub_item_count: 0,
          due_date: nil,
          flagged: false
        )
      end

      before do
        allow(external_task).to receive(:respond_to?) { |method| method == :sub_item_count }
        allow(external_task).to receive(:try).with(:asana_id).and_return(asana_task.id)
      end

      it "does not attempt to change the project" do
        expect(HTTParty).not_to receive(:post)
        expect(service).not_to receive(:move_task_to_section)

        service.update_item(asana_task, external_task)
      end
    end

    context "when external task has the same project as asana task" do
      # asana_task.project is "Pets:Bucky" from the fixture
      let(:external_task) do
        double(
          "ExternalTask",
          completed?: false,
          title: "Test Task",
          project: "Pets:Bucky",
          sync_notes: "notes",
          sub_item_count: 0,
          due_date: nil,
          flagged: false
        )
      end

      before do
        allow(external_task).to receive(:respond_to?) { |method| method == :sub_item_count }
        allow(external_task).to receive(:try).with(:asana_id).and_return(asana_task.id)
      end

      it "does not attempt to change the project" do
        expect(HTTParty).not_to receive(:post)
        expect(service).not_to receive(:move_task_to_section)

        service.update_item(asana_task, external_task)
      end
    end
  end
end
