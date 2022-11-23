# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Asana::Service" do
  let(:service) { Asana::Service.new(options) }
  let(:options) { {} }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  describe "#sync_from_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new({}) }
    end
  end

  describe "#sync_to_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new({}) }
    end
  end

  describe "#tasks_to_sync" do
    subject { service.tasks_to_sync }
  end

  describe "#add_task" do
    subject { service.add_task(external_task, parent_task_gid) }

    let(:external_task) { nil }
    let(:parent_task_gid) { nil }
    let(:title) { "Test" }

    before do
      allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
    end

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end

    context "with Omnifocus task" do
      let(:external_task) { Omnifocus::Service.new.tasks_to_sync(projects: "TaskBridge:Test").first }

      context "with a regular task" do
      end

      context "with a task with a subtask" do
      end

      context "with a task in a section" do
      end
    end
  end

  describe "#update_task" do
    subject { service.update_task(asana_task, external_task) }

    let(:asana_task) { nil }
    let(:external_task) { nil }

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end
end
