# frozen_string_literal: true

require "rails_helper"

RSpec.describe Asana::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}) }
  let(:base_options) do
    full_options.merge(
      logger: logger,
      sync_started_at: "2024-01-01T09:00:00.000000Z",
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

  describe "#memberships_for_task" do
    let(:pets_project_gid) { "1203152506994879" }
    let(:bucky_section_gid) { "1203152506994884" }
    let(:untitled_section_gid) { "1203152506994880" }

    let(:projects_list) do
      [
        { "gid" => pets_project_gid, "name" => "Pets" },
        { "gid" => "9999", "name" => "Other Project" }
      ]
    end

    let(:pets_sections_list) do
      [
        { "gid" => untitled_section_gid, "name" => "Untitled section", "project_gid" => pets_project_gid },
        { "gid" => bucky_section_gid, "name" => "Bucky", "project_gid" => pets_project_gid }
      ]
    end

    before do
      allow(service).to receive(:list_projects).and_return(projects_list)
      allow(service).to receive(:list_project_sections)
        .with(pets_project_gid, merge_project_gids: true)
        .and_return(pets_sections_list)
    end

    context "when external task has a matching section tag" do
      let(:external_task) do
        double("ExternalTask", project: "Pets", tags: ["Bucky"])
      end

      context "for creating a task (for_create: true)" do
        it "returns the project GID" do
          result = service.send(:memberships_for_task, external_task, for_create: true)
          expect(result).to eq({ projects: [pets_project_gid] })
        end
      end

      context "for updating a task (for_create: false)" do
        it "returns both project and section GIDs" do
          result = service.send(:memberships_for_task, external_task, for_create: false)
          expect(result).to eq({ project: pets_project_gid, section: bucky_section_gid })
        end
      end
    end

    context "when external task has just project name" do
      let(:external_task) do
        double("ExternalTask", project: "Pets", tags: [])
      end

      context "for creating a task (for_create: true)" do
        it "returns the project GID" do
          result = service.send(:memberships_for_task, external_task, for_create: true)
          expect(result).to eq({ projects: [pets_project_gid] })
        end
      end

      context "for updating a task (for_create: false)" do
        it "returns only the project GID with no section" do
          result = service.send(:memberships_for_task, external_task, for_create: false)
          expect(result).to eq({ project: pets_project_gid })
        end
      end
    end

    context "when external task uses legacy Project:Section format" do
      let(:external_task) do
        double("ExternalTask", project: "Pets:Bucky", tags: [])
      end

      it "falls back to the project suffix when no section tag matches" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({ project: pets_project_gid, section: bucky_section_gid })
      end
    end

    context "when the project name itself contains a colon" do
      let(:ops_project_gid) { "ops-project-123" }
      let(:ops_section_gid) { "ops-section-456" }
      let(:projects_list) do
        super() + [{ "gid" => ops_project_gid, "name" => "Ops:Infra" }]
      end
      let(:ops_sections_list) do
        [
          { "gid" => ops_section_gid, "name" => "Doing", "project_gid" => ops_project_gid }
        ]
      end
      let(:external_task) do
        double("ExternalTask", project: "Ops:Infra", tags: ["Doing"])
      end

      before do
        allow(service).to receive(:list_project_sections)
          .with(ops_project_gid, merge_project_gids: true)
          .and_return(ops_sections_list)
      end

      it "preserves the full project name for project and section matching" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({ project: ops_project_gid, section: ops_section_gid })
      end
    end

    context "when external task has a section that does not exist" do
      let(:external_task) do
        double("ExternalTask", project: "Pets", tags: ["NonExistentSection"])
      end

      it "returns the project GID with no section" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({ project: pets_project_gid })
      end
    end

    context "when external task has a project that does not exist" do
      let(:external_task) do
        double("ExternalTask", project: "NonExistentProject", tags: ["SomeSection"])
      end

      it "returns an empty hash and warns once" do
        result = nil
        expect do
          2.times { result = service.send(:memberships_for_task, external_task, for_create: false) }
        end.to output("[Asana] No matching Asana project for \"NonExistentProject\"\n").to_stderr
        expect(result).to eq({})
      end
    end

    context "when external task has nil project" do
      let(:external_task) do
        double("ExternalTask", project: nil, tags: ["Bucky"])
      end

      it "returns an empty hash" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({})
      end
    end

    context "when external task has blank project" do
      let(:external_task) do
        double("ExternalTask", project: "", tags: ["Bucky"])
      end

      it "returns an empty hash" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({})
      end
    end

    context "when section tag contains a colon" do
      let(:colon_project_gid) { "colon-project-123" }
      let(:projects_list_with_colon) do
        [
          { "gid" => colon_project_gid, "name" => "Project" }
        ]
      end
      let(:colon_sections_list) do
        [
          { "gid" => "section-with-colon", "name" => "With:Colon:Section", "project_gid" => colon_project_gid }
        ]
      end

      before do
        allow(service).to receive(:list_projects).and_return(projects_list_with_colon)
        allow(service).to receive(:list_project_sections)
          .with(colon_project_gid, merge_project_gids: true)
          .and_return(colon_sections_list)
      end

      let(:external_task) do
        double("ExternalTask", project: "Project", tags: ["With:Colon:Section"])
      end

      it "correctly parses the project and section parts" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({ project: colon_project_gid, section: "section-with-colon" })
      end
    end
  end

  describe "#section_change_requested?" do
    let(:pets_project_gid) { "1203152506994879" }
    let(:bucky_section_gid) { "1203152506994884" }
    let(:projects_list) do
      [
        { "gid" => pets_project_gid, "name" => "Pets" }
      ]
    end
    let(:pets_sections_list) do
      [
        { "gid" => bucky_section_gid, "name" => "Bucky", "project_gid" => pets_project_gid }
      ]
    end
    let(:asana_task) { double("AsanaTask", section: "Bucky") }

    before do
      allow(service).to receive(:list_projects).and_return(projects_list)
      allow(service).to receive(:list_project_sections)
        .with(pets_project_gid, merge_project_gids: true)
        .and_return(pets_sections_list)
    end

    it "returns false for unrelated tags that do not map to an Asana section" do
      external_task = double("ExternalTask", project: "Pets", tags: ["urgent"])
      allow(external_task).to receive(:respond_to?).with(:tags).and_return(true)

      expect(service.send(:section_change_requested?, asana_task, external_task)).to be(false)
    end

    it "returns true when tags are explicitly empty and the task has a section" do
      external_task = double("ExternalTask", project: "Pets", tags: [])
      allow(external_task).to receive(:respond_to?).with(:tags).and_return(true)

      expect(service.send(:section_change_requested?, asana_task, external_task)).to be(true)
    end

    it "does not clear a legacy Project:Section task just because tags are empty" do
      external_task = double("ExternalTask", project: "Pets:Bucky", tags: [])
      allow(external_task).to receive(:respond_to?).with(:tags).and_return(true)

      expect(service.send(:section_change_requested?, asana_task, external_task)).to be(false)
    end

    it "matches sections for projects whose names contain colons" do
      allow(service).to receive(:list_projects).and_return([{ "gid" => "ops-project-123", "name" => "Ops:Infra" }])
      allow(service).to receive(:list_project_sections)
        .with("ops-project-123", merge_project_gids: true)
        .and_return([{ "gid" => "ops-section-456", "name" => "Doing", "project_gid" => "ops-project-123" }])

      external_task = double("ExternalTask", project: "Ops:Infra", tags: ["Doing"])
      allow(external_task).to receive(:respond_to?).with(:tags).and_return(true)

      expect(service.send(:section_change_requested?, double("AsanaTask", section: "Doing"), external_task)).to be(false)
    end

    it "clears sections for projects whose names contain colons when tags are empty" do
      allow(service).to receive(:list_projects).and_return([{ "gid" => "ops-project-123", "name" => "Ops:Infra" }])
      allow(service).to receive(:list_project_sections)
        .with("ops-project-123", merge_project_gids: true)
        .and_return([{ "gid" => "ops-section-456", "name" => "Doing", "project_gid" => "ops-project-123" }])

      external_task = double("ExternalTask", project: "Ops:Infra", tags: [])
      allow(external_task).to receive(:respond_to?).with(:tags).and_return(true)

      expect(service.send(:section_change_requested?, double("AsanaTask", section: "Doing"), external_task)).to be(true)
    end
  end

  describe "#membership_for" do
    let(:ops_project_gid) { "ops-project-123" }
    let(:asana_task) do
      double(
        "AsanaTask",
        synced_project_gid: nil,
        project: "Ops:Infra",
        asana_task: {
          "projects" => [],
          "memberships" => [
            { "project" => { "gid" => "fallback-project" }, "section" => { "gid" => "fallback-section" } },
            { "project" => { "gid" => ops_project_gid }, "section" => { "gid" => "ops-section-456" } }
          ]
        }
      )
    end

    before do
      allow(service).to receive(:list_projects).and_return([{ "gid" => ops_project_gid, "name" => "Ops:Infra" }])
    end

    it "matches memberships against the full project name" do
      result = service.send(:membership_for, asana_task)
      expect(result.dig("section", "gid")).to eq("ops-section-456")
    end
  end

  describe "#project_gid_from_name" do
    let(:pets_project_gid) { "1203152506994879" }
    let(:project_name) { "Pets" }
    let(:projects_list) do
      [
        { "gid" => pets_project_gid, "name" => "Pets" },
        { "gid" => "9999", "name" => "Other Project" }
      ]
    end
    let(:projects_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        body: { data: projects_list }.to_json
      )
    end

    it "memoizes the project list lookup" do
      allow(service).to receive(:workspace_gids).and_return(["workspace-gid"])
      allow(HTTParty).to receive(:get).with(
        "https://app.asana.com/api/1.0/workspaces/workspace-gid/projects",
        hash_including(query: { archived: false })
      ).and_return(projects_response)

      expect(service.send(:project_gid_from_name, project_name)).to eq(pets_project_gid)
      expect(service.send(:project_gid_from_name, project_name)).to eq(pets_project_gid)
      expect(HTTParty).to have_received(:get).once
    end
  end
end
