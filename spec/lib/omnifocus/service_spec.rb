# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Omnifocus::Service" do
  let(:service) { Omnifocus::Service.new(options) }
  let(:options) { {} }

  describe "#tasks_to_sync" do
    subject { service.tasks_to_sync(tags:, projects:, folder:, inbox:, incomplete_only:) }

    let(:tags) { nil }
    let(:projects) { nil }
    let(:folder) { nil }
    let(:inbox) { false }
    let(:incomplete_only) { true }

    it "returns an empty array" do
      expect(subject).to eq([])
    end

    context "with tags" do
      let(:tags) { ["TaskBridge"] }

      it "returns tasks with a matching tag" do
        expect(subject).not_to be_empty
      end
    end

    context "with projects" do
      let(:projects) { "TaskBridge" }

      it "returns tasks in a project" do
        expect(subject.count).to eq(1)
      end
    end

    context "with a folder" do
      let(:folder) { "TaskBridge" }

      it "returns all tasks in a folder" do
        expect(subject.count).to eq(3)
      end
    end

    context "with inbox: true" do
      let(:inbox) { true }

      it "returns inbox tasks" do
        expect(subject.length).to eq(service.send(:inbox_tasks).length)
      end
    end
  end

  describe "#add_task" do
  end

  describe "#update_task" do
  end
end
