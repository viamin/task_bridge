# frozen_string_literal: true

module GoogleKeep
  class Item < Base::SyncItem
    # Keep list items have no stable API ID, so we embed one invisibly in the text payload.
    MARKER_SEPARATOR = "\u2063\u2063"
    ZERO_BIT = "\u200B"
    ONE_BIT = "\u200C"

    attr_accessor :keep_item
    attr_reader :note_title, :sub_items, :sub_item_count

    def read_original(only_modified_dates: false)
      list_item = keep_item.fetch(:item)
      raw_text = item_text_for(list_item)
      stable_external_id = self.class.external_id_from_text(raw_text)

      @note_title = keep_item[:note_title].to_s
      self.last_modified = note_last_modified
      self.title = self.class.visible_text(raw_text)
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
      @stable_external_id_embedded = stable_external_id.present?
      self.external_id = stable_external_id || external_id.presence || SecureRandom.uuid
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

    def stable_external_id_embedded?
      @stable_external_id_embedded == true
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

      def text_with_external_id(text, external_id)
        "#{visible_text(text)}#{encoded_external_id(external_id)}"
      end

      def visible_text(text)
        split_external_id(text).first
      end

      def external_id_from_text(text)
        split_external_id(text).last
      end

      private

      def split_external_id(text)
        raw_text = text.to_s
        visible_text, separator, encoded_external_id = raw_text.rpartition(MARKER_SEPARATOR)
        return [raw_text, nil] if separator.blank?

        decoded_external_id = decoded_external_id(encoded_external_id)
        return [raw_text, nil] if decoded_external_id.blank?

        [visible_text, decoded_external_id]
      end

      def encoded_external_id(external_id)
        bitstream = external_id.to_s.each_byte.map { |byte| byte.to_s(2).rjust(8, "0") }.join
        encoded_bits = bitstream.tr("01", "#{ZERO_BIT}#{ONE_BIT}")
        "#{MARKER_SEPARATOR}#{encoded_bits}"
      end

      def decoded_external_id(encoded_external_id)
        return if encoded_external_id.blank?
        return unless encoded_external_id.chars.all? { |char| [ZERO_BIT, ONE_BIT].include?(char) }
        return unless (encoded_external_id.length % 8).zero?

        decoded_bytes = encoded_external_id.chars.each_slice(8).map do |bits|
          bits.map { |bit| bit == ONE_BIT ? "1" : "0" }.join.to_i(2)
        end
        decoded_bytes.pack("C*").force_encoding(Encoding::UTF_8)
      end
    end

    private

    def keep_path
      Array(keep_item[:path])
    end

    def note_last_modified
      read_external_attribute(keep_item[:note], :update_time)
    end

    def item_text_for(list_item)
      text_content = read_external_attribute(list_item, :text)
      read_external_attribute(text_content, :text).to_s
    end

    def item_checked?(list_item)
      read_external_attribute(list_item, :checked) == true
    end

    def child_items_for(list_item)
      Array(read_external_attribute(list_item, :child_list_items))
    end
  end
end
