# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_items
#
#  id                 :integer          not null, primary key
#  completed          :boolean
#  completed_at       :datetime
#  completed_on       :datetime
#  due_at             :datetime
#  due_date           :datetime
#  flagged            :boolean
#  item_type          :string
#  last_modified      :datetime
#  notes              :string
#  start_at           :datetime
#  start_date         :datetime
#  status             :string
#  title              :string
#  type               :string
#  url                :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  external_id        :string
#  parent_item_id     :integer
#  sync_collection_id :integer
#
# Indexes
#
#  index_sync_items_on_parent_item_id      (parent_item_id)
#  index_sync_items_on_sync_collection_id  (sync_collection_id)
#
# Foreign Keys
#
#  parent_item_id      (parent_item_id => sync_items.id)
#  sync_collection_id  (sync_collection_id => sync_collections.id)
#
require "rails_helper"

RSpec.describe Instapaper::Article do
  let(:title) { Faker::Lorem.sentence }
  let(:folder) { %w[unread archive].sample }
  let(:article_props) do
    {
      "id" => "id_string",
      "title" => title,
      "url" => Faker::Internet.url,
      "folder" => folder,
      "tags" => ["Instapaper"],
      "progress_timestamp" => Chronic.parse("2 weeks ago").to_i,
      "updated_at" => Chronic.parse("1 week ago")
    }
  end
  let(:article) { Instapaper::Article.new(instapaper_article: article_props) }

  describe "#completed?" do
    before { allow(article).to receive(:unread?).and_return(true) }

    it "returns the opposite of unread?" do
      expect(article.completed?).to be(false)
    end
  end

  describe "#unread?" do
    context "when folder is 'unread'" do
      let(:folder) { "unread" }

      it "is true" do
        expect(article).to be_unread
      end
    end

    context "when folder is 'archive'" do
      let(:folder) { "archive" }

      it "is false" do
        expect(article).not_to be_unread
      end
    end
  end

  describe "#friendly_title" do
    it "adds [READ] to the beginning" do
      expect(article.friendly_title).to eq("[READ] #{article.title}")
    end

    context "when title is blank" do
      let(:title) { nil }

      it "returns the URL with [READ] at the beginning" do
        expect(article.friendly_title).to eq("[READ] #{article.url}")
      end
    end
  end
end
