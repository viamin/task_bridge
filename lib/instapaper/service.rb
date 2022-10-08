require_relative "article"
require_relative "authentication"

module Instapaper
  # A service class to connect to the Instapaper Full API
  class Service
    attr_reader :options, :authentication

    def initialize(options)
      @options = options
      @authentication = Authentication.new(options).authenticate
    end

    # Instapaper only syncs TO another service
    def sync(primary_service)
      articles = unread_and_recent_articles
      existing_tasks = primary_service.tasks_to_sync(inbox: true)
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: articles.length, title: "Instapaper articles") if options[:verbose]
      articles.each do |article|
        output = if (existing_task = existing_tasks.find { |task| article.task_title.downcase == task.title.downcase })
          # update the existing task
          primary_service.update_task(existing_task, article, options)
        elsif article.unread?
          # add a new task
          primary_service.add_task(article, options)
        end
        progressbar.log output if !output.blank? && ((options[:pretend] && options[:verbose]) || options[:debug])
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{articles.length} Instapaper articles to #{options[:primary]}" if options[:verbose]
    end

    # not currently supported
    def prune
      false
    end

    private

    def unread_and_recent_articles
      (unread_articles + recently_archived_articles).uniq { |article| article.id }
    end

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
  end
end
