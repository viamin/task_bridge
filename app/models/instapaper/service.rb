# frozen_string_literal: true

module Instapaper
  # A service class to connect to the Instapaper Full API
  class Service < Base::Service
    include GlobalOptions

    UNREAD_ARTICLE_COUNT = 50
    ARCHIVED_ARTICLE_COUNT = 25

    attr_reader :authentication

    def initialize
      super
      @authentication = Authentication.new(options).authenticate!
    rescue
      # If authentication fails, skip the service
      nil
    end

    def item_class
      Article
    end

    def friendly_name
      "Instapaper"
    end

    def sync_strategies
      [:to_primary]
    end

    def items_to_sync(*)
      (unread_articles + recently_archived_articles).uniq(&:external_id)
    end

    def article_text(article)
      debug("Getting article fulltext for article: #{article.title}", options[:debug])
      params = {
        bookmark_id: article.external_id
      }
      response = authentication.get("/bookmarks/get_text?#{URI.encode_www_form(params)}")
      if response.code.to_i == 200
        response.body
      else
        puts "#{response.code} There was a problem with the Instapaper request for #{article.title}"
      end
    end

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      30.minutes.to_i
    end

    def recently_archived_articles
      debug("Getting recently archived Instapaper articles", options[:debug])
      params = {
        limit: ARCHIVED_ARTICLE_COUNT,
        folder_id: "archive"
      }
      response = authentication.get("/bookmarks/list?#{URI.encode_www_form(params)}")
      raise "#{response.code} There was a problem with the Instapaper request" unless response.code.to_i == 200

      articles = JSON.parse(response.body)
      articles.select { |article| article["type"] == "bookmark" }.map do |external_article|
        article = Article.find_or_initialize_by(external_id: external_article[Article.attributes[:external_id]])
        article.instapaper_article = external_article.merge("folder" => "archive")
        article.read_original(only_modified_dates: true)
      end
    end

    def unread_articles
      debug("Getting unread Instapaper articles", options[:debug])
      params = {limit: UNREAD_ARTICLE_COUNT}
      response = authentication.get("/bookmarks/list?#{URI.encode_www_form(params)}")
      raise "#{response.code} There was a problem with the Instapaper request" unless response.code.to_i == 200

      articles = JSON.parse(response.body)
      articles.select { |article| article["type"] == "bookmark" }.map do |external_article|
        article = Article.find_or_initialize_by(external_id: external_article[Article.attributes[:external_id]])
        article.instapaper_article = external_article.merge("folder" => "unread")
        article.read_original(only_modified_dates: true)
      end
    end
  end
end
