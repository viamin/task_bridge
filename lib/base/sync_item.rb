# frozen_string_literal: true

module Base
  class SyncItem
    prepend MemoWise
    include NoteParser

    attr_reader :options, :tags, :notes, :debug_data
    attr_accessor :sync_id, :sync_url

    def initialize(sync_item:, options:)
      @options = options
      @debug_data = sync_item if @options[:debug]
      @tags = default_tags
      attributes = standard_attribute_map.merge(attribute_map).compact
      attributes.each do |attribute_key, attribute_value|
        value = read_attribute(sync_item, attribute_value)
        value = Chronic.parse(value) if chronic_attributes.include?(attribute_key)
        instance_variable_set("@#{attribute_key}", value)
        define_singleton_method(attribute_key.to_sym) { instance_variable_get("@#{attribute_key}") }
      end

      @sync_id, @sync_url, @notes = parsed_notes(keys: %w[sync_id sync_url], notes: read_attribute(sync_item, attributes[:notes]))
    end

    def attribute_map
      raise "not implemented in #{self.class.name}"
    end

    # no, this is a list of attributes that are always there, it's a list of
    # attributes that need to be parsed by Chronic, the date/time parsing gem
    def chronic_attributes
      []
    end

    def provider
      raise "not implemented in #{self.class.name}"
    end

    def service
      if options[:primary] == provider
        options[:primary_service]
      else
        "#{provider}::Service".safe_constantize.new(options:)
      end
    end
    memo_wise :service

    # First, check for a matching sync_id, if supported. Then, check for matching titles
    def find_matching_item_in(collection = [])
      id_match = collection.find { |item| id == item.sync_id } if respond_to?(:id) && sync_id
      return id_match if id_match

      # This should only match older items that don't have sync_ids
      # TODO: this should be removed after items have updated their sync_ids
      notes_and_title_match = collection.find do |item|
        friendly_title_matches(item) && notes == item.notes
      end
      return notes_and_title_match if notes_and_title_match

      collection.find do |item|
        friendly_title_matches(item)
      end
    end

    def friendly_title
      title.strip
    end

    def friendly_title_matches(item)
      friendly_title.downcase == item.friendly_title.downcase
    end

    def sync_notes
      notes_with_values(notes, sync_id:, url: sync_url)
    end

    def to_s
      "#{provider}::#{self.class.name}: (#{id})#{friendly_title}"
    end

    # Converts the task to a format required by the primary service
    def to_primary
      raise "Unsupported service" unless TaskBridge.task_services.include?(options[:primary])

      send("to_#{options[:primary]}".downcase.to_sym)
    end

    # Sync items that use an API to update attributes need to call the service's patch_item method
    # Items that use applescript to update attributes can override this method
    def update_attributes(attributes)
      service.patch_item(self, attributes) if attributes_have_changed?(attributes)
    end

    private

    def default_tags
      options[:tags] + [provider]
    end

    def standard_attribute_map
      {
        id: "id",
        completed_at: "completed_at",
        completed: "completed",
        created_at: "created_at",
        due_at: "due_at",
        due_date: "due_date",
        flagged: "flagged",
        notes: "notes",
        start_at: "start_at",
        start_date: "start_date",
        status: "status",
        title: "title",
        type: "type",
        updated_at: "updated_at",
        url: "url"
      }
    end

    def attributes_have_changed?(attributes)
      attributes.any? { |key, value| send(key.to_sym) != value }
    end

    # used to convert a sync_item back to the original attribute names
    def inverted_attributes
      standard_attribute_map.merge(attribute_map.compact).invert.with_indifferent_access
    end

    # read attributes using applescript
    def read_attribute(sync_item, attribute)
      value = if sync_item.is_a? Hash
        sync_item.fetch(attribute, nil)
      elsif sync_item.respond_to?(attribute.to_sym)
        sync_item.send(attribute.to_sym)
      end
      value = value.get if value.respond_to?(:get)
      value == :missing_value ? nil : value
    end
  end
end
