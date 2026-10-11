# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox, :full_options do
  let(:classes) do
    {
      asana: item_class("BackfillAsanaItem", "Asana"),
      github: item_class("BackfillGithubItem", "Github"),
      omnifocus: item_class("BackfillOmniFocusItem", "Omnifocus"),
      google_tasks: item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(type, collection:, service_name: nil)
    classes.fetch(type).create!(
      title: "#{type} task",
      external_id: "#{type}-#{collection.id}",
      sync_collection: collection,
      options: options.merge(service_name: service_name || type.to_s.camelize)
    )
  end

  it "backfills baseline snapshots and only confident mappings idempotently" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    tentative = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    asana = create_item(:asana, collection: confirmed, service_name: "Asana:work")
    create_item(:github, collection: confirmed, service_name: "Github:repo")
    omnifocus = create_item(:omnifocus, collection: inferred)
    create_item(:google_tasks, collection: inferred)
    create_item(:asana, collection: tentative, service_name: "Asana:personal")

    described_class.run!
    first_rows = OutboxEntry.order(:id).pluck(:id, :idempotency_key)
    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id))
      .to contain_exactly(asana.external_id, "github-#{confirmed.id}", "omnifocus-#{inferred.id}", "google_tasks-#{inferred.id}")
    expect(OutboxEntry.order(:id).pluck(:id, :idempotency_key)).to eq(first_rows)

    asana_row = OutboxEntry.find_by!(record_kind: "item", external_id: asana.external_id)
    omnifocus_row = OutboxEntry.find_by!(record_kind: "item", external_id: omnifocus.external_id)
    expect(asana_row.payload.dig("provenance", "detected_by")).to eq("backfill")
    expect(asana_row.payload["backfilled_at"]).to be_present
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
  end

  it "reports service, confidence, and incomplete-record counts without writing in dry-run mode" do
    collection = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(:github, collection:)
    incomplete = classes.fetch(:asana).create!(title: "Incomplete", options: options)
    incomplete.update_columns(last_observed_at: nil)
    output = StringIO.new

    summary = described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.count).to eq(0)
    expect(summary[:items]).to include("github" => 1)
    expect(summary[:skipped]).to include("missing_external_id:asana" => 1, "low_confidence_mapping:low:github" => 1)
    expect(JSON.parse(output.string)).to include("items" => include("github" => 1))
    expect(incomplete.reload.last_observed_at).to be_nil
  end
end
