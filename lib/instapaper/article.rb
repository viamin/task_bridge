# frozen_string_literal: true

module Instapaper
  class Article
    prepend MemoWise

    attr_reader :options, :id, :folder, :project, :title, :tags, :url, :updated_at, :reading_time

    def initialize(instapaper_article, options)
      @options = options
      @id = instapaper_article["bookmark_id"]
      @title = instapaper_article["title"]
      @url = instapaper_article["url"]
      @folder = instapaper_article["folder"]
      @tags = default_tags
      @project = ENV.fetch("INSTAPAPER_PROJECT", nil)
      @updated_at = Time.at(instapaper_article["progress_timestamp"])
      @reading_time = nil
    end

    def completed?
      !unread?
    end

    def unread?
      folder == "unread"
    end

    def task_title
      if title.strip.blank?
        "[READ] #{url}"
      else
        "[READ] #{title.strip}"
      end
    end

    def properties
      {
        name: task_title,
        note: url,
        estimated_minutes: reading_time
      }.compact
    end

    # calculates a reading time in minutes for the article
    def read_time(instapaper_service)
      # Using the algorithm detailed here:
      # https://blog.medium.com/read-time-and-you-bc2048ab620c
      reading_speed_wpm = 275
      content = instapaper_service.article_text(self)
      doc = Loofah.document(content)
      image_count = doc.search("img").count
      word_count = doc.to_text.tr("\n", " ").squeeze(" ").strip.split.count
      word_reading_minutes = (word_count.to_f / reading_speed_wpm)
      @reading_time = (word_reading_minutes + image_time(image_count)).ceil
    end
    memo_wise :read_time

    private

    def default_tags
      options[:tags] + ["Instapaper"]
    end

    def image_time(image_count)
      # because I'm too lazy to do the math on this...
      precalculated = [12, 23, 33, 42, 50, 57, 63, 68, 72, 75]
      seconds = if image_count <= 10
        precalculated[image_count - 1]
      else
        precalculated.last + ((image_count - 10) * 3)
      end
      seconds.to_f / 60
    end
    memo_wise :image_time

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
