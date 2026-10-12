# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox, :full_options do
  let(:item_classes) do
    {
      omnifocus: backfill_item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: backfill_item_class("BackfillAsanaItem", "Asana"),
      github: backfill_item_class("BackfillGithubItem", "Github"),
      google_tasks: backfill_item_class("BackfillGoogleTasksItem", "Google Tasks")
    }
  end

  def backfill_item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def item(service, external_id, collection: nil)
    item_classes.fetch(service).create!(
      title: "Release checklist", external_id:, sync_collection: collection,
      options: options.merge(service_name: service_name_for(service))
    )
  end

  def service_name_for(service)
    { omnifocus: "Omnifocus", asana: "Asana:work", github: "Github:repo-1", google_tasks: "Google Tasks" }.fetch(service)
  end

  def establish_provenance!
    SyncBackfill::SourceProvenance.run!
  end

  it "seeds idempotent baseline snapshots for representative services without change observations" do
    members = %i[omnifocus asana github google_tasks].map { |service| item(service, "#{service}-1") }
    establish_provenance!

    first_summary = described_class.run!
    second_summary = described_class.run!
    rows = OutboxEntry.where(record_kind: "item").order(:external_id)

    expect(first_summary).to eq(second_summary)
    expect(rows.size).to eq(4)
    expect(rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
    expect(rows.find_by(external_id: "omnifocus-1").service_instance).to eq("omnifocus:default")
    expect(rows.find_by(external_id: "google_tasks-1").service_instance).to eq("google_tasks:default")
    expect(rows).to all(have_attributes(event_type: nil))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(rows.first.payload.dig("provenance", "baseline")).to be(true)
    expect(rows.first.payload.dig("provenance", "detected_by")).to eq("backfill")
    expect(members).to all(be_persisted)
  end

  it "publishes confirmed and inferred memberships, withholds tentative baseline mappings, and reports them in dry run" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    tentative = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    item(:asana, "asana-1", collection: confirmed)
    item(:github, "github-1", collection: inferred)
    item(:omnifocus, "omnifocus-1", collection: tentative)
    establish_provenance!

    output = StringIO.new
    dry_summary = described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.all).to be_empty
    expect(dry_summary).to include(mappings_by_confidence: { "high" => 1, "medium" => 1 })
    expect(dry_summary.fetch(:skipped)).to include("mapping:low_confidence" => 1)
    expect(JSON.parse(output.string)).to include("mappings_by_confidence" => { "high" => 1, "medium" => 1 })

    described_class.run!

    mappings = OutboxEntry.where(record_kind: "mapping").order(:external_id)
    expect(mappings.map(&:external_id)).to contain_exactly("asana-1", "github-1")
    expect(mappings.map { |row| row.payload["mapping_confidence"] }).to contain_exactly("confirmed", "inferred")
  end
end
