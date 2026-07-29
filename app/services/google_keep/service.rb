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
          options:
        ).tap { |item| item.read_original(only_modified_dates:) }
      end
    end

    def sync_to_primary(primary_service, service_items: nil)
      return @last_sync_data unless should_sync?

      service_items ||= items_to_sync(tags: options[:tags], only_modified_dates: true)
      result = super
      stamp_keep_ids!(service_items) if should_stamp_keep_ids?(result, service_items)
      result
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

      page_token = nil
      notes = []

      loop do
        response = keep_notes_page(page_token:)
        notes.concat(Array(response.notes))
        page_token = response.next_page_token
        break if page_token.blank?
      end

      notes
    end

    def list_items_for(note)
      Array(note.body&.list&.list_items)
    end

    def rebuild_keep_note!(primary_items)
      previous_note = keep_note
      note, keep_ids = build_note(primary_items)
      @keep_note = keep_service.create_note(note)
      persist_keep_ids!(keep_ids)
      delete_replaced_keep_note!(previous_note, @keep_note)
    end

    def delete_keep_note!
      note = keep_note
      return sync_result(0, touched_collection_ids: [], errors: []) if note.nil?

      keep_service.delete_note(note.name)
      @keep_note = nil
      sync_result(0, touched_collection_ids: [], errors: [])
    end

    def delete_replaced_keep_note!(previous_note, replacement_note)
      return if previous_note.nil?
      return if previous_note.name == replacement_note&.name

      keep_service.delete_note(previous_note.name)
    end

    def build_note(primary_items)
      keep_ids = {}
      note = Google::Apis::KeepV1::Note.new(
        title: options[:list],
        body: Google::Apis::KeepV1::Section.new(
          list: Google::Apis::KeepV1::ListContent.new(
            list_items: primary_items.filter_map { |item| build_list_item(item, keep_ids) }
          )
        )
      )
      [note, keep_ids]
    end

    def build_list_item(item, keep_ids)
      keep_id = keep_id_for(item)
      keep_ids[item] = keep_id
      payload = {
        checked: item.completed?,
        text: Google::Apis::KeepV1::TextContent.new(text: Item.text_with_external_id(item.title.to_s, keep_id))
      }
      child_list_items = Array(item.sub_items).filter_map { |sub_item| build_list_item(sub_item, keep_ids) }
      payload[:child_list_items] = child_list_items if child_list_items.any?
      Google::Apis::KeepV1::ListItem.new(**payload)
    end

    def keep_notes_page(page_token:)
      request_options = { page_size: 100 }
      request_options[:page_token] = page_token if page_token.present?
      keep_service.list_notes(**request_options)
    end

    def keep_id_for(item)
      sync_note_value(item, :google_keep_id).presence ||
        (item.external_id if item.is_a?(Item) && item.external_id.present?) ||
        SecureRandom.uuid
    end

    def persist_keep_ids!(keep_ids)
      keep_ids.each do |item, keep_id|
        next if item.is_a?(Item)
        next if sync_note_value(item, :google_keep_id) == keep_id

        update_sync_data(item, keep_id)
      end
    end

    def should_stamp_keep_ids?(result, service_items)
      return false if options[:pretend]
      return false if result["status"] == "failed"
      return false if service_items.blank?

      service_items.any? { |item| missing_embedded_keep_id?(item) }
    end

    def missing_embedded_keep_id?(item)
      return true unless item.stable_external_id_embedded?

      Array(item.sub_items).any? { |sub_item| missing_embedded_keep_id?(sub_item) }
    end

    def stamp_keep_ids!(service_items)
      rebuild_keep_note!(service_items)
    end
  end
end
