# frozen_string_literal: true

module Base
  class SyncItem
    prepend MemoWise
    include Debug
    include NoteParser

    attr_reader :options, :tags, :notes, :debug_data

    def initialize(sync_item:, options:)
      @options = options
      @debug_data = sync_item if @options[:debug]
      @tags = default_tags
      attributes = standard_attribute_map.merge(attribute_map).compact
      raw_notes = read_attribute(sync_item, attributes.delete(:notes))
      attributes.each do |attribute_key, attribute_value|
        value = read_attribute(sync_item, attribute_value)
        value = Chronic.parse(value) if chronic_attributes.include?(attribute_key)
        instance_variable_set("@#{attribute_key}", value)
        define_singleton_method(attribute_key.to_sym) { instance_variable_get("@#{attribute_key}") }
      end
      return if raw_notes.blank?

      note_components = parsed_notes(keys: all_service_keys, notes: raw_notes)
      note_components.each do |key, value|
        instance_variable_set("@#{key}", value)
        define_singleton_method(key.to_sym) { instance_variable_get("@#{key}") }
        define_singleton_method(:"#{key}=") { |val| instance_variable_set("@#{key}", val) }
      end
    end

    def completed?
      completed
    end

    def incomplete?
      !completed?
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
    def find_matching_item_in(collection)
      return if collection.blank?

      external_id = :"#{collection.first.provider.underscore}_id"
      service_id = :"#{provider.underscore}_id"
      id_match = collection.find { |item| (item.id && (item.id == try(external_id))) || (item.try(service_id) && (item.try(service_id) == id)) }
      return id_match if id_match

      collection.find do |item|
        friendly_title_matches(item)
      end
    end

    def friendly_title
      title.strip
    end

    def friendly_title_matches(item)
      friendly_title.casecmp(item.friendly_title).zero?
    end

    def external_sync_notes
      notes_with_values(sync_notes, "#{provider.underscore}_id": id, "#{provider.underscore}_url": url)
    end

    def sync_notes
      service_values = {}
      all_services(remove_current: true).map do |service|
        service_values["#{service.underscore}_id"] = instance_variable_get("@#{service.underscore}_id")
        service_values["#{service.underscore}_url"] = instance_variable_get("@#{service.underscore}_url")
      end
      notes_with_values(notes, service_values.compact)
    end
    memo_wise :sync_notes

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
      service.patch_item(self, attributes) if service.respond_to?(:patch_item) && attributes_have_changed?(attributes)
    end

    private

    def all_services(remove_current: false)
      all_services = options[:services] + [options[:primary]]
      all_services.delete(provider) if remove_current
      all_services
    end
    memo_wise :all_services

    def all_service_keys
      all_services(remove_current: true).map { |service| ["#{service.underscore}_id", "#{service.underscore}_url"] }.flatten
    end
    memo_wise :all_service_keys

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

    # read attributes using applescript
    def read_attribute(sync_item, attribute)
      return if attribute.nil?

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
