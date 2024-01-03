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

module Instapaper
  class Article < Base::SyncItem
    attr_accessor :instapaper_article
    attr_reader :folder, :project, :estimated_minutes

    def read_original(only_modified_dates: false)
      super(only_modified_dates:)
      @folder = read_attribute(instapaper_article, "folder", only_modified_dates:)
      @project = Chamber.dig(:instapaper, :project)
      self.last_modified = Time.at(instapaper_article["progress_timestamp"])
      @estimated_minutes = nil
      self
    end

    def external_data
      instapaper_article
    end

    def provider
      "Instapaper"
    end

    def completed?
      !unread?
    end

    def unread?
      folder == "unread"
    end

    def friendly_title
      if title&.strip.blank?
        "[READ] #{url}"
      else
        "[READ] #{title.strip}"
      end
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
      @estimated_minutes = (word_reading_minutes + image_time(image_count)).ceil
    end

    class << self
      def attribute_map
        {
          external_id: "bookmark_id",
          last_modified: nil
        }
      end
    end

    private

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
