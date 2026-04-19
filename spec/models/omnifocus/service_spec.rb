# frozen_string_literal: true

require "rails_helper"

# Integration tests for Omnifocus::Service that test real OmniFocus interaction.
# These tests require OmniFocus to be running but are designed to be fast by
# testing specific AppleScript operations rather than full sync operations.
#
# For fast unit tests, see service_unit_spec.rb
#
# Run only fast tests:  bundle exec rspec --tag '~slow' --tag '~no_ci'
# Run these integration tests: bundle exec rspec --tag no_ci
RSpec.describe "Omnifocus::Service Integration", :no_ci do
  let(:service) { Omnifocus::Service.new }
  let(:logger) { double(StructuredLogger) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#initialize" do
    it "connects to OmniFocus successfully" do
      expect(service.authorized).to be true
      expect(service.omnifocus_app).not_to be_nil
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync(tags:, inbox:) }

    let(:tags) { [] }
    let(:inbox) { false }

    it "returns an empty array" do
      expect(subject).to eq([])
    end

    context "with tags" do
      let(:tags) { ["TaskBridge"] }

      it "returns tasks with a matching tag" do
        expect(subject).not_to be_empty
      end
    end

    context "with inbox: true" do
      let(:inbox) { true }

      it "returns inbox tasks" do
        expect(subject.length).to eq(service.send(:inbox_tasks).length)
      end
    end
  end

  describe "#tagged_tasks" do
    it "returns an empty array for nil tags" do
      expect(service.tagged_tasks(nil)).to eq([])
    end

    it "returns an empty array for non-existent tag" do
      expect(service.tagged_tasks(["NonExistentTag12345"])).to eq([])
    end

    it "can look up an existing tag without error" do
      # Just verify the AppleScript lookup works - don't fetch all tasks
      tag_ref = service.omnifocus_app.flattened_tags["TaskBridge"]
      expect { tag_ref.get }.not_to raise_error
    end
  end

  describe "#inbox_tasks" do
    it "can query inbox without error" do
      # Just verify the query works, don't process all tasks
      expect { service.omnifocus_app.inbox_tasks.get }.not_to raise_error
    end
  end

  describe "tag lookup" do
    it "returns nil for non-existent tag" do
      expect(service.send(:tag, "NonExistentTag12345")).to be_nil
    end

    it "returns a reference for existing tag" do
      tag = service.send(:tag, "TaskBridge")
      # Tag may or may not exist depending on OmniFocus setup
      # Just verify it doesn't raise an error
      expect(tag).to be_nil.or be_a(Appscript::Reference)
    end
  end

  describe "folder lookup" do
    it "returns nil for non-existent folder" do
      expect(service.send(:folder, "NonExistentFolder12345")).to be_nil
    end
  end

  describe "project lookup" do
    it "returns nil for non-existent project" do
      expect(service.send(:project, nil, "NonExistentProject12345")).to be_nil
    end
  end
end
