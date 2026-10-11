# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox"] }
  let(:service_options) { options.merge(tags: [], services: [], primary: "Omnifocus") }

  before { task.reenable }

  it "backfills representative source snapshots and only publishable mappings idempotently" do
    confirmed = SyncCollection.create!(title: "Confirmed")
    inferred = SyncCollection.create!(title: "Inferred")
    tentative = SyncCollection.create!(title: "Tentative")
    omnifocus = create_item(Omnifocus::Task, confirmed, source: { external_id: "of-1", service_name: "Omnifocus", peer: "Asana" })
    asana_source = { external_id: "asana-1", service_name: "Asana:work", peer: "Omnifocus" }
    create_item(Asana::Task, confirmed, source: asana_source, notes: "omnifocus_id: of-1")
    create_item(Github::Issue, inferred, source: { external_id: "gh-1", service_name: "Github:repo", peer: nil })
    create_item(GoogleTasks::Task, inferred, source: { external_id: "gt-1", service_name: "GoogleTasks", peer: nil })
    create_item(Omnifocus::Task, tentative, source: { external_id: "of-2", service_name: "Omnifocus", peer: nil })
    inferred.update_columns(
      mapping_method: "title_fallback", mapping_confidence: "medium", mapping_metadata: { "matched_by" => "title" }
    )

    task.invoke
    entries = OutboxEntry.order(:id).to_a
    task.reenable
    task.invoke

    expect(entries.count { |entry| entry.record_kind == "item" }).to eq(5)
    expect(entries.count { |entry| entry.record_kind == "mapping" }).to eq(4)
    expect(OutboxEntry.count).to eq(entries.count)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_type)).to include(
      "omnifocus", "asana", "github", "google_tasks"
    )
    expect(OutboxEntry.where(record_kind: "item").find_by(external_id: "of-1").payload).to include(
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => a_string_matching(/Z\z/))
    )
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload)).to all(
      include("mapping_confidence" => a_string_matching(/confirmed|inferred/))
    )
    expect(omnifocus.reload.source_service_instance).to be_nil
    expect(OutboxEntry.find_by(external_id: "of-1").service_instance).to eq("omnifocus:default")
  end

  it "reports a non-mutating dry run including withheld tentative mappings" do
    collection = SyncCollection.create!(title: "Tentative")
    create_item(Omnifocus::Task, collection, source: { external_id: "of-dry-run", service_name: "Omnifocus", peer: nil })

    ENV["DRY_RUN"] = "true"
    expect { task.invoke }.to output(/"dry_run":true.*"mappings.withheld.tentative.omnifocus":1/).to_stdout
    expect(OutboxEntry.all).to be_empty
    expect(collection.reload.mapping_method).to be_nil
  ensure
    ENV.delete("DRY_RUN")
  end

  def create_item(klass, collection, source:, notes: nil)
    external_id = source.fetch(:external_id)
    service_name = source.fetch(:service_name)
    peer = source.fetch(:peer)
    sync_notes = notes || (peer && "#{peer.downcase}_id: missing")
    item = klass.create!(
      title: collection.title,
      external_id:,
      notes: sync_notes,
      sync_collection: collection,
      options: service_options.merge(service_name:)
    )
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil
    )
    item
  end
end
