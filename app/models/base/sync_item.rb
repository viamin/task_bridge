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
module Base
  class SyncItem < ApplicationRecord
    include Debug
    include GlobalOptions
    include NoteParser

    attr_reader :tags, :notes, :debug_data

    delegate :attributes, :attribute_map, :modified_date_attributes, :read_attribute, to: :class

    after_initialize :read_notes, :set_tags # , :read_original

    validates :external_id, uniqueness: true

    def read_original(only_modified_dates: false)
      values_hash = attributes.to_h do |attribute_key, attribute_value|
        value = read_attribute(external_data, attribute_value, only_modified_dates:)
        value = Chronic.parse(value) if value && chronic_attributes.include?(attribute_key)
        [attribute_key, value]
      end.compact
      assign_attributes(values_hash)
      self
    end

    def read_notes
      raw_notes = read_attribute(external_data, attributes[:notes])
      return if raw_notes.blank?

      note_components = parsed_notes(keys: all_service_keys, notes: raw_notes)
      note_components.each do |key, value|
        instance_variable_set(:"@#{key}", value)
        define_singleton_method(key.to_sym) { instance_variable_get(:"@#{key}") }
        define_singleton_method(:"#{key}=") { |val| instance_variable_set(:"@#{key}", val) }
      end
    end

    def completed?
      completed
    end

    def incomplete?
      !completed?
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
        options[:primary_service].new
      else
        "#{provider}::Service".safe_constantize.new(options:)
      end
    end

    # First, check for a matching sync_id, if supported. Then, check for matching titles
    def find_matching_item_in(collection)
      return if collection.blank?

      external_id = :"#{collection.first.provider.underscore}_id"
      service_id = :"#{provider.underscore}_id"
      id_match = collection.find { |item| (item.external_id && (item.external_id == try(external_id))) || (item.try(service_id) && (item.try(service_id) == external_id)) }
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
      notes_with_values(sync_notes, "#{provider.underscore}_id": external_id, "#{provider.underscore}_url": url)
    end

    def sync_notes
      service_values = {}
      all_services(remove_current: true).map do |service|
        service_values["#{service.underscore}_id"] = instance_variable_get(:"@#{service.underscore}_id")
        service_values["#{service.underscore}_url"] = instance_variable_get(:"@#{service.underscore}_url")
      end
      notes_with_values(notes, service_values.compact)
    end

    def to_s
      "#{provider}::#{self.class.name}: (#{external_id})#{friendly_title}"
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

    class << self
      def attributes
        standard_attribute_map.merge(attribute_map).compact
      end

      # read attributes using applescript or hash keys
      def read_attribute(external_data, attribute, only_modified_dates: false)
        return if attribute.nil? || (only_modified_dates && !modified_date_attributes.include?(attribute))

        value = if external_data.is_a? Hash
          external_data.fetch(attribute, nil)
        elsif external_data.respond_to?(attribute.to_sym)
          external_data.send(attribute.to_sym)
        end
        value = value.get if value.respond_to?(:get)
        (value == :missing_value) ? nil : value
      end

      def attribute_map
        raise "not implemented in #{self.class}"
      end

      private

      def standard_attribute_map
        {
          external_id: "id",
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
          item_type: "type",
          last_modified: "updated_at",
          url: "url"
        }
      end

      def modified_date_attributes
        %i[completed_at last_modified]
      end
    end

    private

    def all_services(remove_current: false)
      all_services = options[:services] + [options[:primary]]
      all_services.delete(provider) if remove_current
      all_services
    end

    def all_service_keys
      all_services(remove_current: true).map { |service| ["#{service.underscore}_id", "#{service.underscore}_url"] }.flatten
    end

    def set_tags
      @tags = default_tags
    end

    def default_tags
      options[:tags] + [provider]
    end

    def external_data
      raise "Not implemented"
    end

    def attributes_have_changed?(attributes)
      attributes.any? { |key, value| send(key.to_sym) != value }
    end
  end
end
