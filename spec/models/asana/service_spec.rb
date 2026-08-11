# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Asana::Service" do
  let(:service) { Asana::Service.new }
  let(:min_sync_interval) { service.send(:min_sync_interval) }
  let(:last_sync_time) { Time.now - min_sync_interval }
  let(:interval_since_last_sync) { Time.now - last_sync_time }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced) do |_instance, _service_name, interval: false|
      if interval
        Time.now - last_sync_time
      else
        last_sync_time
      end
    end
  end

  describe "#sync_with_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new }

      it "responds to #sync_with_primary" do
        expect(service).to be_respond_to(:sync_with_primary)
      end
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync }

    let(:service) { Asana::Service.new }
    let(:workspaces_response) { instance_double(HTTParty::Response, success?: true, body: { data: [{ "gid" => "workspace-1" }] }.to_json) }
    let(:projects_response) { instance_double(HTTParty::Response, success?: true, body: { data: [{ "gid" => "project-1", "name" => "Project One" }] }.to_json) }
    let(:tasks_response) do
      instance_double(HTTParty::Response, success?: true, body: { data: [task_payload] }.to_json)
    end
    let(:task_payload) do
      {
        "gid" => "asana-123",
        "name" => "Persisted Task",
        "completed" => false,
        "completed_at" => nil,
        "modified_at" => "2024-04-03T12:00:00Z",
        "notes" => "",
        "projects" => [{ "gid" => "project-1", "name" => "Project One" }],
        "memberships" => [],
        "num_subtasks" => 0
      }
    end

    before do
      allow(service).to receive(:service_name).and_return("Asana:work")
      allow(HTTParty).to receive(:get).with("https://app.asana.com/api/1.0/workspaces", anything).and_return(workspaces_response)
      allow(HTTParty).to receive(:get).with("https://app.asana.com/api/1.0/workspaces/workspace-1/projects", anything).and_return(projects_response)
      allow(HTTParty).to receive(:get).with("https://app.asana.com/api/1.0/projects/project-1/tasks", anything).and_return(tasks_response)
      allow(HTTParty).to receive(:get).with("https://app.asana.com/api/1.0/tasks/asana-123/subtasks", anything).and_return(
        instance_double(HTTParty::Response, success?: true, body: { data: [] }.to_json)
      )
    end

    it "stores instance-qualified service options on loaded items" do
      item = subject.first

      Thread.current[:global_options] = service.options.merge(service_name: "Asana:personal", instance_name: "personal")

      expect(item.service_name).to eq("Asana:work")
      expect(item.service_key).to eq("asana_work")
    ensure
      Thread.current[:global_options] = nil
    end
  end

  describe "incremental fetch cursors" do
    let(:response) { instance_double(HTTParty::Response, success?: true, body: { data: [] }.to_json) }

    before do
      allow(HTTParty).to receive(:get).and_return(response)
    end

    it "does not apply modified_since to full project reads" do
      service.send(:list_project_tasks, "project-gid", only_modified_dates: false)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/projects/project-gid/tasks",
        hash_including(query: hash_excluding(:modified_since))
      )
    end

    it "applies modified_since to incremental project reads" do
      service.send(:list_project_tasks, "project-gid", only_modified_dates: true)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/projects/project-gid/tasks",
        hash_including(query: hash_including(:modified_since))
      )
    end

    it "does not apply modified_since to full subtask reads" do
      service.send(:list_task_sub_items, "task-gid", only_modified_dates: false)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/tasks/task-gid/subtasks",
        hash_including(query: hash_excluding(:modified_since))
      )
    end

    it "applies modified_since to incremental subtask reads" do
      service.send(:list_task_sub_items, "task-gid", only_modified_dates: true)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/tasks/task-gid/subtasks",
        hash_including(query: hash_including(:modified_since))
      )
    end
  end

  describe "#workspace_gids" do
    let(:workspaces) do
      [
        { "gid" => "workspace-1" },
        { "gid" => "workspace-2" }
      ]
    end
    let(:workspaces_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        body: { data: workspaces }.to_json
      )
    end

    it "uses the workspaces endpoint" do
      allow(HTTParty).to receive(:get).with(
        "https://app.asana.com/api/1.0/workspaces",
        anything
      ).and_return(workspaces_response)

      expect(service.send(:workspace_gids)).to eq(%w[workspace-1 workspace-2])
      expect(service.send(:workspace_gids)).to eq(%w[workspace-1 workspace-2])
      expect(HTTParty).to have_received(:get).once
    end
  end

  describe "multiple service instances" do
    it "loads credentials from the named Asana instance config" do
      allow(Chamber).to receive(:dig).with(:asana, "work").and_return({ "personal_access_token" => "work-token" })

      instance_service = Asana::Service.new(options: { quiet: true, service_name: "Asana:work", instance_name: "work" })

      expect(instance_service.authorized).to be(true)
      expect(instance_service.service_name).to eq("Asana:work")
      expect(instance_service.send(:authenticated_options).dig(:headers, :Authorization)).to eq("Bearer work-token")
    end
  end

  describe "#list_projects" do
    let(:workspace_gids) { %w[workspace-1 workspace-2] }
    let(:workspace_1_projects) do
      [
        { "gid" => "project-1", "name" => "Project One" }
      ]
    end
    let(:workspace_2_projects) do
      [
        { "gid" => "project-2", "name" => "Project Two" }
      ]
    end
    let(:workspace_1_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        body: { data: workspace_1_projects }.to_json
      )
    end
    let(:workspace_2_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        body: { data: workspace_2_projects }.to_json
      )
    end

    before do
      allow(service).to receive(:workspace_gids).and_return(workspace_gids)
    end

    it "aggregates projects from each workspace" do
      expect(HTTParty).to receive(:get).with(
        "https://app.asana.com/api/1.0/workspaces/workspace-1/projects",
        hash_including(query: { archived: false })
      ).and_return(workspace_1_response)
      expect(HTTParty).to receive(:get).with(
        "https://app.asana.com/api/1.0/workspaces/workspace-2/projects",
        hash_including(query: { archived: false })
      ).and_return(workspace_2_response)

      expect(service.send(:list_projects)).to eq(workspace_1_projects + workspace_2_projects)
    end
  end

  describe "#should_sync?" do
    subject { service.should_sync?(task_updated_at) }

    context "when task_updated_at is nil" do
      let(:task_updated_at) { nil }

      context "when not enough time has passed since last sync" do
        let(:last_sync_time) { (Time.now - min_sync_interval) + 60.seconds }
        let(:interval_since_last_sync) { Time.now - last_sync_time }

        it { is_expected.to be false }
      end

      context "when enough time has passed since last sync" do
        let(:last_sync_time) { (Time.now - min_sync_interval) - 60.seconds }
        let(:interval_since_last_sync) { Time.now - last_sync_time }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("#{min_sync_interval - 1.second} seconds ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Time.now - (min_sync_interval + 1.minute) }

      it { is_expected.to be false }
    end
  end

  describe "#add_item" do
    let(:external_task) do
      instance_double(Asana::Task,
                      title: "Test Task",
                      completed?: false,
                      due_at: nil,
                      due_date: nil,
                      flagged: false,
                      sync_notes: "", notes_content: "",
                      project: "Project One",
                      sub_item_count: 0)
    end
    let(:created_payload) do
      { "gid" => "new-task-1", "name" => "Test Task", "completed" => false,
        "num_subtasks" => 0, "memberships" => [], "projects" => [] }
    end
    let(:create_response) do
      instance_double(HTTParty::Response, success?: true, body: { data: created_payload }.to_json)
    end
    let(:captured_posts) { [] }

    before do
      allow(service).to receive(:memberships_for_task).and_return(projects: ["project-1"])
      allow(service).to receive(:section_identifier_for).and_return("section-1")
      allow(service).to receive(:move_task_to_section).and_return(nil)
      allow(service).to receive(:update_sync_data).and_return(nil)
      allow(HTTParty).to receive(:post) do |url, opts|
        captured_posts << { url:, body: opts[:body] }
        create_response
      end
    end

    def first_post_data
      JSON.parse(captured_posts.first[:body])["data"]
    end

    context "when creating a top-level task" do
      it "posts to the tasks endpoint with project memberships" do
        service.add_item(external_task)

        expect(captured_posts.first[:url]).to end_with("/tasks")
        expect(first_post_data).to include("projects" => ["project-1"])
      end

      it "moves the task into the matching section" do
        service.add_item(external_task)

        expect(service).to have_received(:move_task_to_section).with("section-1", "new-task-1")
      end
    end

    context "when creating a subtask (parent_task_gid present)" do
      it "posts to the parent task's subtasks endpoint" do
        service.add_item(external_task, "parent-task-1")

        expect(captured_posts.first[:url]).to end_with("/tasks/parent-task-1/subtasks")
      end

      it "does not include project memberships in the request body" do
        service.add_item(external_task, "parent-task-1")

        expect(first_post_data).not_to have_key("projects")
      end

      it "does not resolve project memberships for the subtask" do
        service.add_item(external_task, "parent-task-1")

        expect(service).not_to have_received(:memberships_for_task)
      end

      it "does not move the subtask into a section" do
        service.add_item(external_task, "parent-task-1")

        expect(service).not_to have_received(:move_task_to_section)
      end
    end
  end

  describe "#update_item" do
    subject { service.update_item(asana_task, external_task) }

    let(:asana_task) { nil }
    let(:external_task) { nil }

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end

  describe "#skip_create?" do
    subject { service.skip_create?(asana_task) }

    let(:asana_task_json) { JSON.parse(File.read(File.expand_path(Rails.root.join("spec", "fixtures", "asana_task.json")))) }
    let(:asana_task) { Asana::Task.new(asana_task: asana_task_json) }

    context "with a completed task" do
      before { allow(asana_task).to receive(:completed?).and_return(true) }

      it { is_expected.to be true }
    end

    context "with a incomplete task" do
      before { allow(asana_task).to receive(:completed?).and_return(false) }

      context "with a nil assignee" do
        before { allow(asana_task).to receive(:assignee).and_return(nil) }

        it { is_expected.to be false }
      end

      context "with an assignee that matches asana_user" do
        before do
          allow(asana_task).to receive(:assignee).and_return("123")
          allow(service).to receive(:asana_user).and_return({ gid: "123" }.stringify_keys)
        end

        it { is_expected.to be false }
      end

      context "with an assignee that does not match asana_user" do
        before do
          allow(asana_task).to receive(:assignee).and_return("123")
          allow(service).to receive(:asana_user).and_return({ gid: "456" }.stringify_keys)
        end

        it { is_expected.to be true }
      end
    end
  end
end
