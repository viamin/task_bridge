# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }

  def item_class(constant_name, provider_name)
    stub_const(constant_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(klass, **attributes)
    klass.create!(
      title: attributes.fetch(:title, "Baseline task"),
      external_id: attributes.fetch(:external_id),
      notes: attributes.fetch(:notes, ""),
      sync_collection: attributes.fetch(:collection),
      options: options.merge(service_name: attributes.fetch(:service_name))
    )
  end

  it "seeds idempotent item snapshots and only confirmed or inferred mappings" do
    asana_class = item_class("BackfillBaselineAsana", "Asana")
    omnifocus_class = item_class("BackfillBaselineOmniFocus", "Omnifocus")
    github_class = item_class("BackfillBaselineGithub", "Github")
    google_tasks_class = item_class("BackfillBaselineGoogleTasks", "GoogleTasks")
    confirmed = SyncCollection.create!(title: "Confirmed")
    inferred = SyncCollection.create!(title: "Inferred")
    withheld = SyncCollection.create!(title: "Withheld")

    create_item(asana_class, external_id: "asana-1", service_name: "Asana:work", collection: confirmed,
                             notes: "omnifocus_id: of-1")
    create_item(omnifocus_class, external_id: "of-1", service_name: "Omnifocus", collection: confirmed,
                                 notes: "asana_work_id: asana-1")
    create_item(github_class, external_id: "gh-1", service_name: "Github:repo", collection: inferred,
                              title: "Same title")
    create_item(google_tasks_class, external_id: "gt-1", service_name: "GoogleTasks:home", collection: inferred,
                                    title: "Same title")
    create_item(github_class, external_id: "gh-low", service_name: "Github:repo", collection: withheld)

    travel_to(observed_at) do
      summary = described_class.run!

      expect(summary[:items]).to include(eligible: 5, enqueued: 5)
      expect(summary[:mappings]).to include(eligible: 4, enqueued: 4, withheld_low_confidence: 1)
    end

    items = OutboxEntry.where(record_kind: "item")
    mappings = OutboxEntry.where(record_kind: "mapping")
    expect(items.count).to eq(5)
    expect(mappings.count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(items.find_by(external_id: "of-1").service_instance).to eq("omnifocus:default")
    expect(items.find_by(external_id: "asana-1").payload.fetch("provenance")).to include(
      "detected_by" => "backfill", "initial_observation" => true
    )
    expect(mappings.map { |row| row.payload.fetch("mapping_confidence") }).to contain_exactly(
      "confirmed", "confirmed", "inferred", "inferred"
    )

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
  end

  it "reports dry-run counts without changing local records or the outbox" do
    github_class = item_class("BackfillDryRunGithub", "Github")
    collection = SyncCollection.create!(title: "Needs review")
    create_item(github_class, external_id: "gh-1", service_name: "Github:repo", collection:)

    summary = described_class.run!(dry_run: true)

    expect(summary[:items]).to include(eligible: 1, enqueued: 0, by_service: { "github" => 1 })
    expect(summary[:skipped]).to include(incomplete_mapping_provenance: 1)
    expect(collection.reload.mapping_method).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end
end
