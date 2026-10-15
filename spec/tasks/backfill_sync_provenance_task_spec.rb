# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_sync_provenance task", :full_options do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_sync_provenance")
  end

  let(:task) { Rake::Task["task_bridge:backfill_sync_provenance"] }
  let(:test_item_class) do
    stub_const("BackfillSyncTaskItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        {}
      end
    end)
  end
  let(:other_item_class) do
    stub_const("BackfillSyncTaskOtherItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end

  before do
    task.reenable
    allow(SyncBackfill::SourceProvenance).to receive(:run!).and_call_original
    test_item_class
    other_item_class
  end

  after do
    Thread.current[:global_options] = nil
  end

  def source_item_class(constant_name, provider_name)
    stub_const(constant_name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }

      define_method(:provider) { provider_name }
      define_method(:external_data) { {} }
    end)
  end

  def existing_item(item_class, external_id:, service_name:, collection: nil)
    item = item_class.create!(
      options: options.merge(service_name:),
      title: "Existing #{external_id}",
      external_id:,
      notes: "Existing notes",
      last_modified: Time.zone.parse("2026-09-01T10:00:00Z"),
      sync_collection: collection
    )
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_created_at: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil,
      last_snapshot: nil
    )
    item
  end

  it "backfills explicit source and mapping provenance idempotently" do
    collection = SyncCollection.create!(title: "Buy milk")
    source_item = test_item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-123",
      notes: "omnifocus_id: of-456",
      sync_collection: collection
    )
    target_item = other_item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-456",
      notes: "asana_work_id: asana-123",
      sync_collection: collection
    )

    source_item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_created_at: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil
    )
    target_item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_created_at: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil
    )
    collection.update_columns(
      mapping_method: nil,
      mapping_confidence: nil,
      mapping_metadata: nil,
      mapping_established_at: nil,
      mapping_last_observed_at: nil
    )

    task.invoke
    task.reenable
    first_run = {
      source_observed_at: source_item.reload.last_observed_at,
      target_observed_at: target_item.reload.last_observed_at,
      collection_observed_at: collection.reload.mapping_last_observed_at,
      collection_updated_at: collection.updated_at
    }

    task.invoke
    task.reenable

    expect(SyncBackfill::SourceProvenance).to have_received(:run!).twice
    expect(source_item.reload.source_service_name).to eq("Asana:work")
    expect(source_item.source_service_instance).to eq("work")
    expect(source_item.source_external_id).to eq("asana-123")
    expect(source_item.source_created_at).to be_nil
    expect(target_item.reload.source_service_name).to eq("Omnifocus")
    expect(target_item.source_created_at).to be_nil
    expect(collection.reload.mapping_method).to eq("source_sync_id")
    expect(collection.mapping_confidence).to eq("high")
    expect(collection.mapping_metadata).to include("note_key" => "omnifocus_id")
    expect(collection.mapping_established_at).to be_present
    expect(collection.mapping_last_observed_at).to be_present
    expect(source_item.reload.last_observed_at).to eq(first_run[:source_observed_at])
    expect(target_item.reload.last_observed_at).to eq(first_run[:target_observed_at])
    expect(collection.reload.mapping_last_observed_at).to eq(first_run[:collection_observed_at])
    expect(collection.updated_at).to eq(first_run[:collection_updated_at])
  end

  it "seeds idempotent baseline snapshots for existing OmniFocus, Asana, GitHub, and Google Tasks items" do
    omnifocus = existing_item(
      source_item_class("BackfillOmniFocusItem", "OmniFocus"),
      external_id: "of-1", service_name: "OmniFocus"
    )
    asana = existing_item(source_item_class("BackfillAsanaItem", "Asana"),
                          external_id: "asana-1", service_name: "Asana:work")
    github = existing_item(source_item_class("BackfillGitHubItem", "GitHub"),
                           external_id: "issue-1", service_name: "GitHub:repo-1")
    google_tasks = existing_item(source_item_class("BackfillGoogleTasksItem", "Google Tasks"),
                                 external_id: "google-1", service_name: "Google Tasks")

    travel_to(Time.zone.parse("2026-10-01T12:00:00Z")) do
      task.invoke
      task.reenable
    end
    original_baseline_rows = OutboxEntry.where(record_kind: "item").order(:id).pluck(:id, :idempotency_key)

    travel_to(Time.zone.parse("2026-10-02T12:00:00Z")) { task.invoke }

    expect(OutboxEntry.where(record_kind: "item")).to match_array(
      [
        have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default", external_id: omnifocus.external_id),
        have_attributes(service_type: "asana", service_instance: "asana:default", external_id: asana.external_id),
        have_attributes(service_type: "github", service_instance: "github:default", external_id: github.external_id),
        have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default", external_id: google_tasks.external_id)
      ]
    )
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:idempotency_key)).to all(include(":snapshot:"))
    expect(OutboxEntry.where(record_kind: "item").pluck(:payload)).to all(
      include(
        "provenance" => include("detected_by" => "backfill", "backfilled_at" => "2026-10-01T12:00:00.000000Z")
      )
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "item").order(:id).pluck(:id, :idempotency_key)).to eq(original_baseline_rows)
  end

  it "publishes confirmed and inferred memberships but withholds tentative baseline mappings" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    tentative = SyncCollection.create!(title: "Tentative", mapping_method: "title_fallback", mapping_confidence: "low")
    item_class = source_item_class("BackfillMappingItem", "Asana")
    existing_item(item_class, external_id: "confirmed-1", service_name: "Asana:work", collection: confirmed)
    existing_item(item_class, external_id: "inferred-1", service_name: "Asana:work", collection: inferred)
    existing_item(item_class, external_id: "tentative-1", service_name: "Asana:work", collection: tentative)

    task.invoke

    mappings = OutboxEntry.where(record_kind: "mapping").order(:external_id)
    expect(mappings.pluck(:external_id)).to contain_exactly("confirmed-1", "inferred-1")
    expect(mappings.map { |entry| entry.payload.fetch("mapping_confidence") }).to contain_exactly("confirmed", "inferred")
    expect(mappings).to all(have_attributes(event_type: nil))
  end

  it "honors --pretend after the rake argument separator without writing changes" do
    confirmed = SyncCollection.create!(
      title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high"
    )
    inferred = SyncCollection.create!(
      title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium"
    )
    complete = existing_item(
      source_item_class("BackfillDryRunItem", "OmniFocus"),
      external_id: "of-dry-run", service_name: "OmniFocus", collection: confirmed
    )
    inferred_item = existing_item(
      source_item_class("BackfillInferredDryRunItem", "Asana"),
      external_id: "asana-dry-run", service_name: "Asana:work", collection: inferred
    )
    incomplete = source_item_class("BackfillIncompleteItem", "Asana").create!(
      options: options.merge(service_name: "Asana"), title: "Incomplete", external_id: nil
    )
    incomplete.update_columns(first_observed_at: nil, last_observed_at: nil)
    item_states = [complete, inferred_item, incomplete].index_with do |item|
      item.attributes.slice(*provenance_and_baseline_attributes)
    end
    collection_states = [confirmed, inferred].index_with do |collection|
      collection.attributes.slice(*mapping_provenance_attributes)
    end

    expect(Thread.current[:global_options]).to be_nil

    aggregate_failures do
      expect { invoke_task("task_bridge:backfill_sync_provenance", "--", "--pretend") }.to output(
        /Backfill dry run:.*items: omnifocus=1, asana=1.*mappings: confirmed=1, inferred=1.*skipped: asana=1/m
      ).to_stdout
      item_states.each do |item, state|
        expect(item.reload.attributes.slice(*provenance_and_baseline_attributes)).to eq(state)
      end
      collection_states.each do |collection, state|
        expect(collection.reload.attributes.slice(*mapping_provenance_attributes)).to eq(state)
      end
      expect(OutboxEntry.all).to be_empty
    end
  end

  def provenance_and_baseline_attributes
    %w[
      source_service_name source_service_instance source_service_type source_external_id source_url
      source_created_at source_updated_at first_observed_at last_observed_at source_metadata last_snapshot updated_at
    ]
  end

  def mapping_provenance_attributes
    %w[mapping_method mapping_confidence mapping_metadata mapping_established_at mapping_last_observed_at updated_at]
  end

  def invoke_task(*args)
    original_argv = ARGV.dup
    ARGV.replace(args)
    task.invoke
  ensure
    ARGV.replace(original_argv)
  end
end
