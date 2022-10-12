require_relative "article"
require_relative "authentication"

module Instapaper
  # A service class to connect to the Instapaper Full API
  class Service
    prepend MemoWise

    attr_reader :options, :authentication

    def initialize(options)
      @options = options
      @authentication = Authentication.new(options).authenticate
    end

    # Instapaper only syncs TO another service
    def sync(primary_service)
      articles = unread_and_recent_articles
      existing_tasks = primary_service.tasks_to_sync(tags: ["Instapaper"], inbox: true)
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: articles.length, title: "Instapaper articles") unless options[:quiet]
      articles.each do |article|
        puts "\n\n#{self.class}##{__method__} Looking for #{article.task_title} (#{article.folder})" if options[:debug]
        output = if (existing_task = existing_tasks.find { |task| article.task_title.downcase == task.title.downcase.strip })
          primary_service.update_task(existing_task, article, options)
        elsif article.unread?
          primary_service.add_task(article, options)
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{articles.length} Instapaper articles to #{options[:primary]}" unless options[:quiet]
    end

    # not currently supported
    def prune
      false
    end

    private

    def unread_and_recent_articles
      (unread_articles + recently_archived_articles).uniq { |article| article.id }
    end
    memo_wise :unread_and_recent_articles

    def recently_archived_articles
      puts "Getting recently archived Instapaper articles" if options[:debug]
      params = {
        limit: "5",
        folder_id: "archive"
      }
      response = authentication.get("/bookmarks/list", params)
      if response.code.to_i == 200
        articles = JSON.parse(response.body)
        articles.select { |article| article["type"] == "bookmark" }.map do |article|
          Article.new(article.merge({"folder" => "archive"}), options)
        end
      else
        raise "#{response.code} There was a problem with the Instapaper request"
      end
    end
    memo_wise :recently_archived_articles

    def unread_articles
      puts "Getting unread Instapaper articles" if options[:debug]
      params = {limit: "100"}
      response = authentication.get("/bookmarks/list", params)
      if response.code.to_i == 200
        articles = JSON.parse(response.body)
        articles.select { |article| article["type"] == "bookmark" }.map do |article|
          Article.new(article.merge({"folder" => "unread"}), options)
        end
      else
        raise "#{response.code} There was a problem with the Instapaper request"
      end
    end
    memo_wise :unread_articles
  end
end
