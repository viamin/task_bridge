module Instapaper
  class Article
    attr_reader :options, :title, :tags

    def initialize(instapaper_article, options)
      @options = options
      @title = instapaper_article["title"]
      @tags = options[:tags].push("Instapaper")
    end

    def unread?
    end

    def task_title
      "[READ] #{title}"
    end
  end
end
