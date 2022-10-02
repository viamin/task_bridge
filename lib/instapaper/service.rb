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
    def sync
      articles = unread_and_recent_articles
      existing_tasks = primary_service.tasks_to_sync
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: articles.length, title: "Instapaper articles") if options[:verbose]
      articles.each do |article|
        if (existing_task = existing_tasks.find { |task| article.task_title.downcase == task.title.downcase })
          # update the existing task
          primary_service.update_task(existing_task, article, options)
        elsif article.unread?
          # add a new task
          primary_service.add_task(article, options)
        end
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{articles.length} Github issues to #{options[:primary]}" if options[:verbose]
    end

    # not currently supported
    def prune
      false
    end

    private

    def authenticated_options
      {
        headers: {

        }
      }
    end

    def unread_and_recent_articles
      (unread_articles + recently_archived_articles).uniq.map { |article| Article.new(article, options) }
    end

    def recently_archived_articles
      params = {params: {
        limit: 5,
        folder_id: "archive"
      }}
      response = HTTParty.get("https://www.instapaper.com/api/1/bookmarks/list", authenticated_options.merge(params))
      if response.code == 200
        JSON.parse(response.body)
      end
    end

    def unread_articles
      params = {params: {limit: 100}}
      response = HTTParty.get("https://www.instapaper.com/api/1/bookmarks/list", authenticated_options.merge(params))
      if response.code == 200
        JSON.parse(response.body)
      end
    end
  end
end
