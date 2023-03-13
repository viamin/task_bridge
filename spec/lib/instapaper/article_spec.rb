# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Instapaper::Article" do
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
  let(:options) { { tags: [] } }
  let(:article) { Instapaper::Article.new(instapaper_article: article_props, options:) }

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
