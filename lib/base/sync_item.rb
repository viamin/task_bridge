# frozen_string_literal: true

module Base
  class SyncItem
    prepend MemoWise
    include NoteParser

    attr_reader :options, :tags, :sync_id, :sync_url, :notes, :debug_data

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
      raise "not implemented"
    end

    def chronic_attributes
      []
    end

    def provider
      raise "not implemented"
    end

    def friendly_title
      title.strip
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
