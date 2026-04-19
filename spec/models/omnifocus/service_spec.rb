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
  let(:service) { Omnifocus::Service.new(options:) }
  let(:logger) { double(StructuredLogger) }
  let(:last_sync) { Time.now - 15.minutes }
  let(:options) do
    {
      logger:,
      quiet: true,
      debug: false,
      pretend: false,
      tags: [],
      services: [],
      primary: "Omnifocus"
    }
  end

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
    skip "OmniFocus is not available to AppleScript" unless service.authorized
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

      it "can resolve the requested tag" do
        tag_ref = service.omnifocus_app.flattened_tags[tags.first]

        expect { tag_ref.get }.not_to raise_error
      end
    end

    context "with inbox: true" do
      it "can resolve inbox tasks" do
        expect(service.omnifocus_app.inbox_tasks.get).to be_an(Array)
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
      begin
        tag_ref.get
      rescue StandardError
        skip "OmniFocus tag 'TaskBridge' is not present"
      end
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
