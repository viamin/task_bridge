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

    context "when external task has 'Project:Section' format" do
      let(:external_task) do
        double("ExternalTask", project: "Pets:Bucky")
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

    context "when external task has just project name (from Untitled section)" do
      let(:external_task) do
        double("ExternalTask", project: "Pets")
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

    context "when external task has a section that does not exist" do
      let(:external_task) do
        double("ExternalTask", project: "Pets:NonExistentSection")
      end

      it "returns the project GID with no section" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({ project: pets_project_gid })
      end
    end

    context "when external task has a project that does not exist" do
      let(:external_task) do
        double("ExternalTask", project: "NonExistentProject:SomeSection")
      end

      it "returns an empty hash" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({})
      end
    end

    context "when external task has nil project" do
      let(:external_task) do
        double("ExternalTask", project: nil)
      end

      it "returns an empty hash" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({})
      end
    end

    context "when external task has blank project" do
      let(:external_task) do
        double("ExternalTask", project: "")
      end

      it "returns an empty hash" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({})
      end
    end

    context "when project name contains colon (edge case: 'Project:With:Colon:Section')" do
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
        # When parsed: project = "Project", section = "With:Colon:Section" (using split(":", 2))
        double("ExternalTask", project: "Project:With:Colon:Section")
      end

      it "correctly parses the project and section parts" do
        result = service.send(:memberships_for_task, external_task, for_create: false)
        expect(result).to eq({ project: colon_project_gid, section: "section-with-colon" })
      end
    end
  end
end
