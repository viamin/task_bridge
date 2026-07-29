# frozen_string_literal: true

require "google/apis/keep_v1"

module GoogleKeep
  class Service < Base::Service
    include GoogleTasks::AuthorizationHelpers

    attr_reader :keep_service, :authorized

    def initialize(options: nil, keep_service: Google::Apis::KeepV1::KeepService.new, authorization: nil)
      super(options:)
      @keep_service = keep_service
      @keep_service.authorization = authorization || user_credentials_for(Google::Apis::KeepV1::AUTH_KEEP)
      @authorized = true
    rescue Signet::AuthorizationError => e
      puts "Google Keep credentials have expired. Delete credentials.yaml and re-authorize"
      puts e.full_message
      @authorized = false
    rescue Google::Apis::AuthorizationError => e
      puts "Google Keep authentication has failed. Please check authorization settings and try again."
      puts e.full_message
      @authorized = false
    end

    def item_class
      Item
    end

    def friendly_name
      "Google Keep"
    end

    def sync_strategies
      %i[from_primary to_primary]
    end

    def items_to_sync(*, only_modified_dates: false, **)
      debug("called", options[:debug])
      note = keep_note
      return [] if note.nil?

      @items_to_sync ||= {}
      @items_to_sync[only_modified_dates] ||= list_items_for(note).each_with_index.filter_map do |list_item, index|
        Item.new(
          keep_item: {
            item: list_item,
            note: note,
            note_title: note.title,
            path: [index]
          },
          options:,
          external_id: synthetic_external_id(note, list_item, [index])
        ).tap { |item| item.read_original(only_modified_dates:) }
      end
    end

    def sync_from_primary(primary_service, _service_items: nil)
      return @last_sync_data unless should_sync?

      sync_errors = []
      touched_collection_ids = []
      if (unavailable_error = service_unavailable_error(primary_service))
        warn_sync_errors([unavailable_error])
        return sync_result(0, touched_collection_ids:, errors: [unavailable_error])
      end

      primary_items = primary_service.items_to_sync(tags: [friendly_name])
      return delete_keep_note! if primary_items.empty?

      rebuild_keep_note!(primary_items)
      puts "Synced #{primary_items.length} #{options[:primary]} items to #{friendly_name}" unless options[:quiet]
      sync_result(primary_items.length, touched_collection_ids:, errors: sync_errors)
    end

    private

    def min_sync_interval
      30.minutes.to_i
    end

    def keep_note
      @keep_note ||= keep_notes.find { |note| note.title == options[:list] && note.body&.list.present? }
    end

    def keep_notes
      return [] unless authorized

      keep_service.list_notes(page_size: 100).notes || []
    end

    def list_items_for(note)
      Array(note.body&.list&.list_items)
    end

    def rebuild_keep_note!(primary_items)
      delete_keep_note!
      @keep_note = keep_service.create_note(build_note(primary_items))
    end

    def delete_keep_note!
      note = keep_note
      return sync_result(0, touched_collection_ids: [], errors: []) if note.nil?

      keep_service.delete_note(note.name)
      @keep_note = nil
      sync_result(0, touched_collection_ids: [], errors: [])
    end

    def build_note(primary_items)
      Google::Apis::KeepV1::Note.new(
        title: options[:list],
        body: Google::Apis::KeepV1::Section.new(
          list: Google::Apis::KeepV1::ListContent.new(
            list_items: primary_items.filter_map { |item| build_list_item(item) }
          )
        )
      )
    end

    def build_list_item(item)
      payload = {
        checked: item.completed?,
        text: Google::Apis::KeepV1::TextContent.new(text: item.title.to_s)
      }
      child_list_items = Array(item.sub_items).filter_map { |sub_item| build_list_item(sub_item) }
      payload[:child_list_items] = child_list_items if child_list_items.any?
      Google::Apis::KeepV1::ListItem.new(**payload)
    end

    def synthetic_external_id(note, list_item, path)
      title = list_item_title(list_item)
      checked = list_item_checked?(list_item) ? "completed" : "open"
      [note.title, *path, title, checked].join("::")
    end

    def list_item_title(list_item)
      text_content = list_item.respond_to?(:text) ? list_item.text : list_item[:text]
      return text_content[:text].to_s if text_content.is_a?(Hash)

      text_content.respond_to?(:text) ? text_content.text.to_s : text_content.to_s
    end

    def list_item_checked?(list_item)
      return list_item.checked == true if list_item.respond_to?(:checked)

      list_item[:checked] == true
    end
  end
end
