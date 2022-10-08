module Instapaper
  class Article
    attr_reader :options, :id, :folder, :project, :title, :tags, :url

    def initialize(instapaper_article, options)
      @options = options
      @id = instapaper_article["bookmark_id"]
      @title = instapaper_article["title"]
      @url = instapaper_article["url"]
      @folder = instapaper_article["folder"]
      @tags = ["Instapaper"]
      @project = ENV.fetch("INSTAPAPER_PROJECT", nil)
    end

    def unread?
      folder == "unread"
    end

    def task_title
      "[READ] #{title}"
    end

    def properties
      {
        name: task_title,
        note: url
      }
    end

    # {
    #   "hash" => "agzVxoVE",
    #   "description" => "",
    #   "bookmark_id" => 1541124736,
    #   "private_source" => "",
    #   "title" => "Compress to impress — Remains of the Day",
    #   "url" => "https://www.eugenewei.com/blog/2017/5/11/jpeg-your-ideas",
    #   "progress_timestamp" => 1665027801,
    #   "time" => 1664438263,
    #   "progress" => 0.72406,
    #   "starred" => "0",
    #   "type" => "bookmark"
    # }
  end
end
