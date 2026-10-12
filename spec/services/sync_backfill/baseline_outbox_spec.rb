# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:options) { { service_name: "Omnifocus", services: [], primary: "Asana", tags: [] } }

  it "seeds stable baseline snapshots for representative existing sources" do
    items = [
      Omnifocus::Task.create!(title: "Omni", external_id: "omni-1", options:),
      Asana::Task.create!(title: "Asana", external_id: "asana-1", options: options.merge(service_name: "Asana:work")),
      Github::Issue.create!(title: "GitHub", external_id: "github-1", github_issue: {},
                            options: options.merge(service_name: "Github:repo")),
      GoogleTasks::Task.create!(title: "Google", external_id: "google-1", options: options.merge(service_name: "GoogleTasks"))
    ]
    items.each { |item| item.update_columns(last_observed_at: observed_at) }

    travel_to(observed_at + 1.hour) do
      described_class.run!(io: StringIO.new)
      described_class.run!(io: StringIO.new)
    end

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.order(:external_id).map { |entry| entry.payload.fetch("baseline") }).to all(be(true))
    expect(OutboxEntry.find_by(external_id: "omni-1").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(external_id: "asana-1").service_instance).to eq("asana:work")
  end

  it "withholds low-confidence mappings and publishes high and medium confidence mappings" do
    high_collection = collection_with(Omnifocus::Task, Asana::Task, "source_sync_id", "high")
    medium_collection = collection_with(Github::Issue, GoogleTasks::Task, "title_fallback", "medium")
    low_collection = collection_with(Omnifocus::Task, Github::Issue, "manual_backfill", "low")

    summary = described_class.run!(io: StringIO.new)

    expect(OutboxEntry.where(record_kind: "mapping", sync_collection: high_collection).count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping", sync_collection: medium_collection).count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping", sync_collection: low_collection)).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").find_by(sync_collection: medium_collection).payload["mapping_confidence"])
      .to eq("inferred")
    expect(summary[:withheld_low_confidence_mappings]).to eq(2)
  end

  it "reports a dry run without changing source, mapping, or outbox records" do
    incomplete = Omnifocus::Task.create!(title: "Incomplete", options:)
    incomplete.update_columns(last_observed_at: nil)
    output = StringIO.new

    expect do
      described_class.run!(dry_run: true, io: output)
    end.not_to change(OutboxEntry, :count)

    expect(incomplete.reload.last_observed_at).to be_nil
    expect(output.string).to include("dry run", "skipped_incomplete_items")
  end

  private

  def collection_with(left_class, right_class, method, confidence)
    collection = SyncCollection.create!(title: "Shared", mapping_method: method, mapping_confidence: confidence)
    left_class.create!(title: "Left", external_id: "#{method}-left-#{collection.id}", sync_collection: collection,
                       options: options.merge(service_name: service_name_for(left_class)))
    right_class.create!(title: "Right", external_id: "#{method}-right-#{collection.id}", sync_collection: collection,
                        options: options.merge(service_name: service_name_for(right_class)))
    collection
  end

  def service_name_for(item_class)
    item_class.name.deconstantize
  end
end
