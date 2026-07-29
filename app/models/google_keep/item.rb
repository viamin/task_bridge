# frozen_string_literal: true

module GoogleKeep
  class Item < Base::SyncItem
    attr_accessor :keep_item
    attr_reader :note_title, :sub_items, :sub_item_count

    def read_original(only_modified_dates: false)
      list_item = keep_item.fetch(:item)
      @note_title = keep_item[:note_title].to_s
      self.last_modified = note_last_modified
      self.title = item_title_for(list_item)
      self.completed = item_checked?(list_item)
      @sub_items = child_items_for(list_item).each_with_index.filter_map do |child_item, index|
        self.class.new(
          keep_item: {
            item: child_item,
            note: keep_item[:note],
            note_title: note_title,
            path: keep_path + [index]
          },
          options:
        ).tap { |item| item.read_original(only_modified_dates:) }
      end
      @sub_item_count = @sub_items.length
      self.external_id = synthetic_external_id
      self
    end

    def external_data
      keep_item.fetch(:item)
    end

    def provider
      "GoogleKeep"
    end

    def personal?
      true
    end

    def project
      note_title
    end

    def completed?
      completed == true
    end

    def incomplete?
      !completed?
    end

    def external_sync_notes
      notes_with_values(notes, google_keep_id: external_id)
    end

    def friendly_title
      title.to_s.strip
    end

    def self.from_external(external_item)
      {
        checked: external_item.completed?,
        text: Google::Apis::KeepV1::TextContent.new(text: external_item.title.to_s)
      }
    end

    class << self
      def attribute_map
        {}
      end
    end

    private

    def keep_path
      Array(keep_item[:path])
    end

    def note_last_modified
      read_external_attribute(keep_item[:note], :update_time)
    end

    def item_title_for(list_item)
      text_content = read_external_attribute(list_item, :text)
      read_external_attribute(text_content, :text).to_s
    end

    def item_checked?(list_item)
      read_external_attribute(list_item, :checked) == true
    end

    def child_items_for(list_item)
      Array(read_external_attribute(list_item, :child_list_items))
    end

    def synthetic_external_id
      [note_title, *keep_path, friendly_title, completed? ? "completed" : "open"].join("::")
    end
  end
end
