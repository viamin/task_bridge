# frozen_string_literal: true

require_relative "article"
require_relative "authentication"
require_relative "../base/service"

module Instapaper
  # A service class to connect to the Instapaper Full API
  class Service < Base::Service
    UNREAD_ARTICLE_COUNT = 50
    ARCHIVED_ARTICLE_COUNT = 25

    attr_reader :authentication

    def initialize(options:)
      @authentication = Authentication.new(options).authenticate!
      super
    rescue StandardError
      # If authentication fails, skip the service
      nil
    end

    def friendly_name
      "Instapaper"
    end

    # Instapaper only syncs TO another service
    def sync_to_primary(primary_service)
      articles = unread_and_recent_articles
      existing_tasks = primary_service.tasks_to_sync(tags: [friendly_name], inbox: true)
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: articles.length,
          title: "Instapaper articles"
        )
      end
      articles.each do |article|
        puts "\n\n#{self.class}##{__method__} Looking for #{article.friendly_title} (#{article.folder})" if options[:debug]
        output = if (existing_task = existing_tasks.find do |task|
                       article.friendly_title.downcase == task.title.downcase.strip
                     end)
          if should_sync?(article.updated_at)
            primary_service.update_task(existing_task, article)
          elsif options[:debug]
            debug("Skipping sync of #{article.title} (should_sync? == false)")
          end
        elsif article.unread?
          article.read_time(self)
          primary_service.add_task(article, options)
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{articles.length} Instapaper articles to #{options[:primary]}" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: articles.length }.stringify_keys
    end

    def article_text(article)
      puts "Getting article fulltext for article: #{article.title}" if options[:debug]
      params = {
        bookmark_id: article.id
      }
      response = authentication.get("/bookmarks/get_text?#{URI.encode_www_form(params)}")
      if response.code.to_i == 200
        response.body
      else
        puts "#{response.code} There was a problem with the Instapaper request for #{article.title}"
      end
    end
    memo_wise :article_text

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      30.minutes.to_i
    end

    def unread_and_recent_articles
      (unread_articles + recently_archived_articles).uniq(&:id)
    end
    memo_wise :unread_and_recent_articles

    def recently_archived_articles
      puts "Getting recently archived Instapaper articles" if options[:debug]
      params = {
        limit: ARCHIVED_ARTICLE_COUNT,
        folder_id: "archive"
      }
      response = authentication.get("/bookmarks/list?#{URI.encode_www_form(params)}")
      raise "#{response.code} There was a problem with the Instapaper request" unless response.code.to_i == 200

      articles = JSON.parse(response.body)
      articles.select { |article| article["type"] == "bookmark" }.map do |article|
        Article.new(instapaper_article: article.merge({ "folder" => "archive" }), options:)
      end
    end
    memo_wise :recently_archived_articles

    def unread_articles
      puts "Getting unread Instapaper articles" if options[:debug]
      params = { limit: UNREAD_ARTICLE_COUNT }
      response = authentication.get("/bookmarks/list?#{URI.encode_www_form(params)}")
      raise "#{response.code} There was a problem with the Instapaper request" unless response.code.to_i == 200

      articles = JSON.parse(response.body)
      articles.select { |article| article["type"] == "bookmark" }.map do |article|
        Article.new(instapaper_article: article.merge({ "folder" => "unread" }), options:)
      end
    end
    memo_wise :unread_articles
  end
end
