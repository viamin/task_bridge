# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Omnifocus::Service", :full_options do
  let(:logger) { instance_double(StructuredLogger) }
  let(:options) { full_options.merge(logger:) }
  let(:service) { Omnifocus::Service.new(options:) }
  let(:last_sync) { Time.now - (15 * 60) }
  let(:omnifocus_document) { instance_double("OmnifocusDocument") }

  def build_task_double(data)
    sub_item_doubles = Array(data[:sub_items]).map { |sub_item| build_task_double(sub_item) }
    double(
      "OmnifocusTask",
      id: data.fetch(:id),
      friendly_title: data.fetch(:title, data[:id]),
      sub_item_count: sub_item_doubles.length,
      sub_items: sub_item_doubles
    )
  end

  before do
    allow(Appscript).to receive_message_chain(:app, :by_name, :default_document).and_return(omnifocus_document)
    allow(logger).to receive(:sync_data_for).with("Omnifocus").and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
    allow(Omnifocus::Task).to receive(:new) do |omnifocus_task:, options:|
      build_task_double(omnifocus_task)
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync(tags: sync_tags, inbox:) }

    let(:sync_tags) { nil }
    let(:inbox) { false }
    let(:tagged_app_tasks_data) { [] }
    let(:inbox_app_tasks_data) { [] }

    before do
      allow(service).to receive(:tagged_tasks).and_return(tagged_app_tasks_data)
      allow(service).to receive(:inbox_tasks).and_return(inbox_app_tasks_data)
    end

    it "returns an empty array", :no_ci do
      expect(subject).to eq([])
    end

    context "with tags" do
      let(:sync_tags) { ["TaskBridge"] }
      let(:tagged_app_tasks_data) do
        [
          { id: "tag-1", title: "Tagged Task" },
          { id: "tag-2", title: "Parent Task", sub_items: [{ id: "tag-2-child", title: "Child Task" }] },
          { id: "tag-2-child", title: "Child Task" }
        ]
      end

      it "returns tasks with a matching tag", :no_ci do
        expect(subject.map(&:id)).to match_array(%w[tag-1 tag-2])
      end
    end

    context "with inbox: true" do
      let(:inbox) { true }
      let(:inbox_app_tasks_data) do
        [
          { id: "inbox-1", title: "Inbox Task" },
          { id: "inbox-2", title: "Inbox Parent", sub_items: [{ id: "inbox-2-child", title: "Inbox Child" }] }
        ]
      end

      it "returns inbox tasks", :no_ci do
        expect(subject.length).to eq(service.send(:inbox_tasks).length)
        expect(subject.map(&:id)).to match_array(%w[inbox-1 inbox-2])
      end
    end
  end

  describe "#item_class" do
    it "returns the Omnifocus::Task class" do
      expect(service.item_class).to eq(Omnifocus::Task)
    end
  end

  describe "#friendly_name" do
    it "returns the service name" do
      expect(service.friendly_name).to eq("Omnifocus")
    end
  end

  describe "#sync_strategies" do
    it "supports syncing from the primary service" do
      expect(service.sync_strategies).to eq([:from_primary])
    end
  end

  describe "#tagged_tasks" do
    let(:tag_reference) do
      instance_double(
        "OmnifocusTag",
        name: instance_double("TagName", get: "TaskBridge")
      )
    end

    before do
      allow(omnifocus_document).to receive_message_chain(:flattened_tags, :get).and_return([tag_reference])
      allow(service).to receive(:all_tasks_in_container).with([tag_reference], incomplete_only: false).and_return(["native-task"])
    end

    it "returns tasks for matching tags" do
      expect(service.tagged_tasks(["TaskBridge"])).to eq(["native-task"])
    end

    it "can filter for incomplete tasks" do
      allow(service).to receive(:all_tasks_in_container).with([tag_reference], incomplete_only: true).and_return(["incomplete-task"])
      expect(service.tagged_tasks(["TaskBridge"], incomplete_only: true)).to eq(["incomplete-task"])
    end
  end

  describe "#min_sync_interval" do
    it "waits at least fifteen minutes between syncs" do
      expect(service.send(:min_sync_interval)).to eq(15.minutes.to_i)
    end
  end

  describe "#add_item" do
    let(:options) { full_options.merge(logger:, pretend: true, verbose: true) }
    let(:external_task) { double("ExternalTask", title: "Sample Task", provider: "Asana") }

    it "evaluates the pretend addition without raising errors" do
      expect(service).to receive(:project).with(external_task).and_return(nil)
      expect(service.add_item(external_task)).to be_nil
    end
  end

  describe "#update_item" do
    let(:options) { full_options.merge(logger:, pretend: true) }
    let(:omnifocus_task) { instance_double("OmnifocusTask", incomplete?: true, id_: double(get: "abc"), original_task: double(id_: double(get: "abc"))) }
    let(:external_task) { double("ExternalTask", completed?: false, title: "Updated Task") }

    it "reports the pretend update" do
      expect(service.update_item(omnifocus_task, external_task)).to eq("Would have updated Updated Task in Omnifocus")
    end
  end

  describe "#inbox_tasks" do
    let(:raw_task) { double("RawTask") }
    let(:expanded_task) { double("ExpandedTask", id_: double(get: "123")) }

    before do
      allow(omnifocus_document).to receive_message_chain(:inbox_tasks, :get).and_return([raw_task])
      allow(service).to receive(:all_omnifocus_sub_items).with(raw_task).and_return([expanded_task])
    end

    it "flattens inbox tasks and removes duplicates" do
      expect(service.inbox_tasks).to eq([expanded_task])
    end
  end

  describe "#inbox_titles" do
    let(:inbox_task) { double("InboxTask", title: "Inbox Task") }

    before do
      allow(service).to receive(:inbox_tasks).and_return([inbox_task])
    end

    it "returns the titles of inbox tasks" do
      expect(service.inbox_titles).to eq(["Inbox Task"])
    end
  end

  describe "#tag" do
    let(:flattened_tags) { double("FlattenedTags") }
    let(:tag_reference) { double("TagReference", get: "TagRef") }

    before do
      allow(omnifocus_document).to receive(:flattened_tags).and_return(flattened_tags)
      allow(flattened_tags).to receive(:[]).with("TaskBridge").and_return(tag_reference)
    end

    it "retrieves a tag by name" do
      expect(service.send(:tag, "TaskBridge")).to eq("TagRef")
    end
  end
end
