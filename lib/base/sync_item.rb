# frozen_string_literal: true

module Base
  class SyncItem
    prepend MemoWise
    include NoteParser

    attr_reader :options, :tags, :debug_data

    def initialize(sync_item:, options:)
      @options = options
      @debug_data = sync_item if @options[:debug]
      @tags = default_tags
      attributes = standard_attribute_map.merge(attribute_map).compact
      attributes.each do |attribute_key, attribute_value|
        value = read_attribute(sync_item, attribute_value)
        value = Chronic.parse(value) if chronic_attributes.include?(attribute_key)
        instance_variable_set("@#{attribute_key}", value)
        self.define_singleton_method(attribute_key.to_sym) { instance_variable_get("@#{attribute_key}") }
      end
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

    # Subclasses should override this
    def attribute_map
      raise "Not implemented"
    end

    def standard_attribute_map
      {
        id: "id",
        title: "title",
        url: "url",
        completed: "completed",
        completed_at: "completed_at",
        due_date: "due_date",
        due_at: "due_at",
        flagged: "flagged",
        type: "type",
        start_date: "start_date",
        start_at: "start_at",
        created_at: "created_at",
        updated_at: "updated_at"
      }
    end

    # read attributes using applescript
    def read_attribute(sync_item, attribute)
      value = if sync_item.is_a? Hash
        sync_item.fetch(attribute, nil)
      else
        sync_item.send(attribute.to_sym) if sync_item.respond_to?(attribute.to_sym)
      end
      value = value.get if value.respond_to?(:get)
      value == :missing_value ? nil : value
    end
  end
end
