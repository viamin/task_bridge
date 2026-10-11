# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:asana_class) { item_class("BackfillAsanaItem", "Asana") }
  let(:github_class) { item_class("BackfillGithubItem", "Github") }
  let(:google_tasks_class) { item_class("BackfillGoogleTasksItem", "GoogleTasks") }
  let(:omnifocus_class) { item_class("BackfillOmnifocusItem", "Omnifocus") }
  let(:service_options) { { services: [], primary: "Asana", tags: [] } }

  before { [asana_class, github_class, google_tasks_class, omnifocus_class] }

  it "seeds idempotent baseline snapshots for representative source services" do
    items = [
      create_item(asana_class, "asana-1", "Asana:work"),
      create_item(github_class, "github-1", "Github:repo"),
      create_item(google_tasks_class, "google-1", "GoogleTasks"),
      create_item(omnifocus_class, "omnifocus-1", "Omnifocus")
    ]

    summary = described_class.run!(backfilled_at:)

    expect(summary[:items]).to include("asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.find_by(external_id: "omnifocus-1").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(external_id: "asana-1").payload).to include(
      "provenance" => include("detected_by" => "backfill", "baseline" => true)
    )

    expect { described_class.run!(backfilled_at: backfilled_at + 1.hour) }
      .not_to(change { OutboxEntry.where(record_kind: "item").count })
    expect(items.map { |item| item.reload.source_service_instance }).to include("default", "work", "repo")
  end

  it "publishes high and medium mapping baselines but withholds low-confidence memberships" do
    confirmed = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    withheld = SyncCollection.create!(title: "Review", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(asana_class, "confirmed-1", "Asana", collection: confirmed)
    create_item(github_class, "inferred-1", "Github", collection: inferred)
    create_item(omnifocus_class, "withheld-1", "Omnifocus", collection: withheld)

    summary = described_class.run!(backfilled_at:)

    expect(summary[:mappings]).to include("high" => 1, "medium" => 1)
    expect(summary[:skipped]).to include(mapping_low: 1)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("confirmed-1", "inferred-1")
    expect(OutboxEntry.find_by(external_id: "inferred-1", record_kind: "mapping").payload["mapping_confidence"])
      .to eq("inferred")
  end

  it "reports a dry run without writing provenance or outbox rows" do
    item = create_item(google_tasks_class, "dry-1", "GoogleTasks")
    item.update_columns(source_service_instance: nil)

    summary = described_class.run!(dry_run: true, backfilled_at:)

    expect(summary[:items]).to include("google_tasks" => 1)
    expect(item.reload.source_service_instance).to be_nil
    expect(OutboxEntry.count).to be_zero
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

  def create_item(klass, external_id, service_name, collection: nil)
    klass.create!(title: external_id, notes: "", external_id:, sync_collection: collection,
                  options: service_options.merge(service_name:))
  end
end
