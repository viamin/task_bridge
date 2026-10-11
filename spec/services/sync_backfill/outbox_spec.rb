# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox, :full_options do
  let(:asana_item_class) { sync_item_class("BackfillAsanaItem", "Asana") }
  let(:omnifocus_item_class) { sync_item_class("BackfillOmnifocusItem", "Omnifocus") }
  let(:github_item_class) { sync_item_class("BackfillGithubItem", "Github") }
  let(:google_tasks_item_class) { sync_item_class("BackfillGoogleTasksItem", "GoogleTasks") }

  before do
    asana_item_class
    omnifocus_item_class
    github_item_class
    google_tasks_item_class
  end

  it "backfills idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    confirmed = SyncCollection.create!(title: "Release checklist")
    tentative = SyncCollection.create!(title: "Needs review")
    asana = create_item(asana_item_class, "Asana:work", "asana-1", confirmed, "omnifocus_id: of-1")
    omnifocus = create_item(omnifocus_item_class, "Omnifocus", "of-1", confirmed, "asana_work_id: asana-1")
    create_item(github_item_class, "Github:repo-1", "issue-1")
    create_item(google_tasks_item_class, "GoogleTasks", "google-1", tentative)

    first_summary = described_class.run!
    described_class.run!

    aggregate_failures do
      expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
      expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly(asana.external_id, omnifocus.external_id)
      expect(OutboxEntry.find_by(external_id: "of-1", record_kind: "item").service_instance).to eq("omnifocus:default")
      expect(OutboxEntry.find_by(external_id: "google-1", record_kind: "item").payload.dig("provenance", "detected_by")).to eq("backfill")
      expect(first_summary).to include("items:asana" => 1, "items:omnifocus" => 1, "items:github" => 1,
                                       "items:google_tasks" => 1, "mappings:high" => 2,
                                       "mappings:low" => 1, withheld_mappings: 1)
    end
  end

  it "reports dry-run counts without writing local provenance or outbox rows" do
    item = create_item(asana_item_class, "Asana:work", "asana-1")
    item.update_columns(source_service_name: nil, source_service_instance: nil, first_observed_at: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    aggregate_failures do
      expect(summary).to include("items:asana" => 1)
      expect(OutboxEntry.count).to eq(0)
      expect(item.reload.source_service_name).to be_nil
    end
  end

  def sync_item_class(name, provider)
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

  def create_item(item_class, service_name, external_id, collection = nil, notes = nil)
    item_class.create!(
      title: "Release checklist",
      external_id:,
      notes:,
      sync_collection: collection,
      options: options.merge(service_name:)
    )
  end
end
