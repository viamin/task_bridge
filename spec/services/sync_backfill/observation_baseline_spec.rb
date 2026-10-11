# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::ObservationBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T10:00:00Z") }
  let(:item_classes) do
    {
      "Omnifocus" => backfill_item_class("BaselineOmnifocusItem", "Omnifocus"),
      "Asana:work" => backfill_item_class("BaselineAsanaItem", "Asana"),
      "Github:repo" => backfill_item_class("BaselineGithubItem", "Github"),
      "GoogleTasks" => backfill_item_class("BaselineGoogleTasksItem", "Google Tasks")
    }
  end

  def backfill_item_class(name, provider)
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

  def create_item(service_name, external_id)
    item_classes.fetch(service_name).create!(
      title: "#{service_name} task",
      external_id:,
      options: { service_name:, services: [], primary: "Omnifocus", tags: [] }
    )
  end

  it "creates idempotent baseline snapshots for supported existing services" do
    travel_to(observed_at) do
      %w[Omnifocus Asana:work Github:repo GoogleTasks].each_with_index do |service_name, index|
        create_item(service_name, "item-#{index}")
      end

      described_class.run!
      described_class.run!
    end

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.size).to eq(4)
    expect(rows.map(&:service_instance)).to contain_exactly(
      "omnifocus:default", "asana:work", "github:repo", "google_tasks:default"
    )
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(rows.map { |row| row.payload.dig("provenance", "baseline") }).to all(be(true))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
  end

  it "publishes only high and medium mapping memberships and reports low ones in a dry run" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    tentative = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item("Omnifocus", "confirmed").update!(sync_collection: confirmed)
    create_item("Asana:work", "inferred").update!(sync_collection: inferred)
    create_item("Github:repo", "tentative").update!(sync_collection: tentative)

    output = StringIO.new
    described_class.run!(dry_run: true, output:)
    report = JSON.parse(output.string)

    expect(report.dig("mappings_by_service_and_confidence", "omnifocus", "high")).to eq(1)
    expect(report.dig("mappings_by_service_and_confidence", "asana", "medium")).to eq(1)
    expect(report.dig("withheld_mappings_by_service_and_confidence", "github", "low")).to eq(1)
    expect(OutboxEntry.count).to eq(0)

    described_class.run!

    mappings = OutboxEntry.where(record_kind: "mapping")
    expect(mappings.map(&:external_id)).to contain_exactly("confirmed", "inferred")
    expect(mappings.find_by(external_id: "inferred").payload["mapping_confidence"]).to eq("inferred")
  end
end
