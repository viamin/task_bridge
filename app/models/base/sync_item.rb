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
#  notes              :text
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
#  index_sync_items_on_last_modified               (last_modified)
#  index_sync_items_on_parent_item_id              (parent_item_id)
#  index_sync_items_on_sync_collection_id          (sync_collection_id)
#  index_sync_items_on_sync_collection_id_and_type (sync_collection_id,type) UNIQUE WHERE (sync_collection_id IS NOT NULL)
#  index_sync_items_on_type_and_external_id        (type,external_id) UNIQUE
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

    self.table_name = "sync_items"

    attr_reader :tags, :debug_data

    delegate :external_attribute_map, :attribute_map, :read_external_attribute, to: :class

    after_initialize :read_notes, :set_tags

    belongs_to :sync_collection, optional: true, inverse_of: :sync_items

    def initialize(attributes = nil, &)
      attributes ||= {}
      # Extract non-column attributes before passing to ActiveRecord
      column_names = self.class.cached_column_names
      association_names = self.class.cached_association_names
      ar_attrs = {}
      extra_attrs = {}
      association_attrs = {}
      attributes.each do |key, value|
        if column_names.include?(key.to_sym)
          ar_attrs[key] = value
        elsif association_names.include?(key.to_sym)
          association_attrs[key] = value
        else
          extra_attrs[key] = value
        end
      end
      # Set extra attributes first so after_initialize callbacks can access them
      extra_attrs.each do |key, value|
        instance_variable_set(:"@#{key}", value)
      end
      super(ar_attrs, &)
      association_attrs.each do |key, value|
        public_send(:"#{key}=", value)
      end
    end

    validates :external_id, uniqueness: { scope: :type }

    def read_original(only_modified_dates: false)
      values_hash = external_attribute_map.each_with_object({}) do |(attribute_key, attribute_value), hash|
        next if only_modified_dates &&
                !self.class.send(:modified_date_attributes).include?(attribute_key) &&
                !self.class.send(:identity_attributes).include?(attribute_key) &&
                !self.class.send(:completion_indicator_attributes).include?(attribute_key)

        value = read_external_attribute(external_data, attribute_value, only_modified_dates:, attribute_key:)
        value = Chronic.parse(value) if value && chronic_attributes.include?(attribute_key)
        hash[attribute_key] = value
      end
      assign_attributes(values_hash)
      # Skip expensive notes parsing (which may trigger API/AppleScript reads)
      # when we only need date and identity attributes for grouping.
      # However, when notes are not already present, we still need to parse sync
      # IDs so metadata-only updates can preserve foreign sync IDs and avoid
      # clearing valid IDs when applying updates.
      read_notes if !only_modified_dates || notes.nil?
      self
    end

    def refresh_from_external!(only_modified_dates: false)
      read_original(only_modified_dates:)
      return self if options[:pretend]

      save! if changed?
      self
    end

    def read_notes
      reset_note_component_values

      # Prefer the already-assigned attribute value so note parsing does not
      # trigger a second external read after read_original has populated notes.
      raw_notes = notes if has_attribute?(:notes)
      raw_notes = self.class.read_external_attribute(external_data, external_attribute_map[:notes]) if raw_notes.nil?
      return if raw_notes.blank?

      note_components = parsed_notes(keys: all_service_keys, notes: raw_notes)
      note_components.each do |key, value|
        next if has_attribute?(key)

        instance_variable_set(:"@#{key}", value)
        define_note_component_accessors(key)
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
      @service ||= if options[:primary] == provider
        # options[:primary_service] may be either a class or an already-instantiated
        # service object (the rake task stores an instance). Handle both cases.
        primary = options[:primary_service]
        primary.is_a?(Class) ? primary.new : primary
      else
        "#{provider}::Service".safe_constantize.new(options:)
      end
    end

    # First, check for a matching sync_id, if supported. Then, check for matching titles
    def find_matching_item_in(collection)
      return if collection.blank?

      target_id_field = :"#{collection.first.provider.underscore}_id"
      source_id_field = :"#{provider.underscore}_id"
      my_target_id = try(target_id_field)

      # First, try to match by sync ID
      id_match = collection.find { |item| (item.external_id && (item.external_id == my_target_id)) || (item.try(source_id_field) && (item.try(source_id_field) == external_id)) }
      return id_match if id_match

      # If we have a sync ID that didn't match anything in the collection,
      # it's stale (the linked item was deleted). Allow title matching as fallback.
      # But only match items that don't already have our sync ID (aren't linked to other items).
      collection.find do |item|
        friendly_title_matches(item) && item.try(source_id_field).blank?
      end
    end

    def friendly_title
      title.to_s.strip
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
      task_services = Chamber.dig!(:task_bridge, :task_services)
      raise "Unsupported service" unless task_services.include?(options[:primary])

      send("to_#{options[:primary]}".downcase.to_sym)
    end

    # Sync items that use an API to update attributes need to call the service's patch_item method.
    # Items that use applescript to update attributes can override this method.
    # Named patch_external_attributes (not update_attributes) to avoid overriding
    # ActiveRecord's own update_attributes/update semantics.
    def patch_external_attributes(attributes)
      service.patch_item(self, attributes) if service.respond_to?(:patch_item) && attributes_have_changed?(attributes)
    end

    def define_note_component_accessors(key)
      return if singleton_class.method_defined?(key.to_sym) && singleton_class.method_defined?(:"#{key}=")

      define_singleton_method(key.to_sym) { instance_variable_get(:"@#{key}") }
      define_singleton_method(:"#{key}=") { |val| instance_variable_set(:"@#{key}", val) }
    end

    class << self
      def cached_column_names
        @cached_column_names ||= column_names.map(&:to_sym).freeze
      end

      def cached_association_names
        @cached_association_names ||= reflections.keys.map(&:to_sym).freeze
      end

      def external_attribute_map
        standard_attribute_map.merge(attribute_map).compact
      end

      # Read a single attribute value from external_data (AppleScript refs or hash keys).
      # Named read_external_attribute (not read_attribute) to avoid shadowing
      # ActiveRecord::Base#read_attribute which is used for DB column access.
      # When only_modified_dates is true, attribute_key must be provided to filter
      # by modified_date_attributes, identity_attributes (title, external_id),
      # and completion_indicator_attributes (completed, status) — the latter are
      # needed because sync.rake grouping calls incomplete? on items read with
      # only_modified_dates: true.
      def read_external_attribute(external_data, attribute, only_modified_dates: false, attribute_key: nil)
        return if attribute.nil?
        return if only_modified_dates && attribute_key &&
                  !modified_date_attributes.include?(attribute_key) &&
                  !identity_attributes.include?(attribute_key) &&
                  !completion_indicator_attributes.include?(attribute_key)

        value = if external_data.is_a? Hash
          external_data.fetch(attribute, nil)
        elsif external_data.respond_to?(attribute.to_sym)
          external_data.send(attribute.to_sym)
        end
        value = value.get if value.respond_to?(:get)
        value == :missing_value ? nil : value
      rescue Appscript::CommandError => e
        # Stale AppleScript references (e.g., OSERROR -1728 "Can't get reference")
        # occur when a task is deleted mid-iteration. Return nil to keep the sync
        # run from crashing.
        raise unless e.to_i == -1728

        nil
      end

      def attribute_map
        raise "not implemented in #{self.class}"
      end

      private

      def standard_attribute_map
        # NOTE: Do not map `created_at` here. AR manages `created_at`/`updated_at`
        # as record timestamps. Populating `created_at` from external data would
        # break ordering, auditing, and Rails conventions. If we need to persist
        # the remote creation time, add a dedicated `external_created_at` column.
        {
          external_id: "id",
          completed_at: "completed_at",
          completed: "completed",
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

      # Attributes that must always be read (even with only_modified_dates)
      # because they are required for item matching and grouping.
      def identity_attributes
        %i[title external_id]
      end

      # Attributes needed to determine completion status. These must be read
      # even with only_modified_dates because sync.rake grouping checks
      # incomplete? on the resulting items. Subclasses whose completed? relies
      # on different fields (e.g., a custom status value) can override this.
      def completion_indicator_attributes
        %i[completed completed_at status]
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

    def reset_note_component_values
      all_service_keys.each do |key|
        instance_variable_set(:"@#{key}", nil)
      end
    end

    def external_data
      raise "Not implemented"
    end

    def attributes_have_changed?(attributes)
      attributes.any? { |key, value| send(key.to_sym) != value }
    end
  end
end
