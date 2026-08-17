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
#  first_observed_at  :datetime
#  item_type          :string
#  last_modified      :datetime
#  last_observed_at   :datetime
#  notes              :text
#  source_created_at  :datetime
#  source_external_id :string
#  source_metadata    :text
#  source_service_instance :string
#  source_service_name :string
#  source_service_type :string
#  source_updated_at  :datetime
#  source_url         :string
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
#  index_sync_items_on_collection_id_and_source_service_name (sync_collection_id,source_service_name) UNIQUE WHERE ((sync_collection_id IS NOT NULL) AND (source_service_name IS NOT NULL))
#  index_sync_items_on_last_modified                     (last_modified)
#  index_sync_items_on_parent_item_id                    (parent_item_id)
#  index_sync_items_on_sync_collection_id                (sync_collection_id)
#  index_sync_items_on_type_service_name_and_external_id (type,source_service_name,external_id) UNIQUE
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
    before_validation :capture_source_identity

    belongs_to :sync_collection, optional: true, inverse_of: :sync_items

    serialize :source_metadata, coder: JSON

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

    validates :external_id, uniqueness: { scope: %i[type source_service_name] }

    def read_original(only_modified_dates: false)
      values_hash = external_attribute_map.each_with_object({}) do |(attribute_key, attribute_value), hash|
        next if only_modified_dates &&
                !self.class.send(:modified_date_attributes).include?(attribute_key) &&
                !self.class.send(:identity_attributes).include?(attribute_key) &&
                !self.class.send(:completion_indicator_attributes).include?(attribute_key)

        value = read_external_attribute(external_data, attribute_value, only_modified_dates:, attribute_key:)
        value = normalize_external_timestamp(value) if attribute_key == :source_created_at
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

      # Always record the observation (not just when attributes changed) so
      # last_observed_at reflects every fetch, not just ones that produced a
      # diff. observe_source! saves unconditionally because it always bumps
      # last_observed_at, which keeps the record dirty.
      observe_source!
    end

    def read_notes
      reset_note_component_values

      # Prefer the already-assigned attribute value so note parsing does not
      # trigger a second external read after read_original has populated notes.
      raw_notes = notes if has_attribute?(:notes)
      raw_notes = self.class.read_external_attribute(external_data, external_attribute_map[:notes]) if raw_notes.nil?
      return if raw_notes.blank?

      note_components = parsed_notes(keys: sync_note_keys(raw_notes), notes: raw_notes)
      note_components.each do |key, value|
        next if has_attribute?(key)

        instance_variable_set(:"@#{key}", value)
        define_note_component_accessors(key)
      end
    end

    def completed?
      completed == true
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

    def service_name
      Base::Service.normalized_service_name(
        source_service_name.presence || @service_name.presence || options[:service_name].presence || provider
      )
    end

    def options
      return @options if defined?(@options) && @options.present?

      super
    end

    def options=(options)
      @options = options
      @service_name = Base::Service.normalized_service_name(options[:service_name]) if options&.[](:service_name).present?
    end

    def service_key
      Base::Service.service_identifier_for(service_name)
    end

    def service
      return @service if defined?(@service) && !@service.nil?

      @service = if options[:primary] == service_name
        primary = options[:primary_service]
        primary.is_a?(Class) ? primary.new : primary
      else
        service_class = Base::Service.resolve_service_class(service_name)
        service_class&.new(options: Base::Service.build_options(options, service_name))
      end
    end

    # First, check for a matching sync_id, if supported. Then, check for matching titles
    def find_matching_item_in(collection)
      return if collection.blank?

      target_id_field = :"#{collection.first.service_key}_id"
      source_id_field = :"#{service_key}_id"
      my_target_id = sync_note_value_for(target_id_field)

      # First, try to match by sync ID
      id_match = collection.find do |item|
        sync_ids_match?(item.external_id, my_target_id) ||
          sync_ids_match?(item.sync_note_value_for(source_id_field), external_id)
      end
      return id_match if id_match

      # If we have a sync ID that didn't match anything in the collection,
      # it's stale (the linked item was deleted). Allow title matching as fallback.
      # But only match items that don't already have our sync ID (aren't linked to other items).
      collection.find do |item|
        friendly_title_matches(item) && item.sync_note_value_for(source_id_field).blank?
      end
    end

    def friendly_title
      title.to_s.strip
    end

    def friendly_title_matches(item)
      friendly_title.casecmp(item.friendly_title).zero?
    end

    def external_sync_notes
      notes_with_values(sync_notes, "#{service_key}_id": external_id, "#{service_key}_url": url)
    end

    def sync_notes
      notes_with_values(notes, sync_id_values)
    end

    # Human-readable notes content with all sync metadata (service ID/URL lines) stripped
    def notes_content
      notes.to_s.gsub(/^[a-z0-9_]+_(?:id|url):\s.*$\R?/, "").strip
    end

    # Notes combining content from source_item with this item's own known sync IDs.
    # Used when syncing content from another item while preserving this item's metadata.
    def sync_notes_from(source_item)
      notes_with_values(source_item.notes_content, sync_id_values)
    end

    def to_s
      "#{service_name}::#{self.class.name}: (#{external_id})#{friendly_title}"
    end

    # Converts the task to a format required by the primary service
    def to_primary
      task_services = Chamber.dig!(:task_bridge, :task_services)
      primary_service_name = Base::Service.class_name_for(options[:primary])
      raise "Unsupported service" unless task_services.include?(primary_service_name)

      send("to_#{primary_service_name}".downcase.to_sym)
    end

    # Sync items that use an API to update attributes need to call the service's patch_item method.
    # Items that use applescript to update attributes can override this method.
    # Named patch_external_attributes (not update_attributes) to avoid overriding
    # ActiveRecord's own update_attributes/update semantics.
    def patch_external_attributes(attributes)
      service.patch_item(self, attributes) if service.respond_to?(:patch_item) && attributes_have_changed?(attributes)
    end

    def sync_note_value_for(key)
      return public_send(key) if respond_to?(key)

      instance_variable = :"@#{key}"
      return instance_variable_get(instance_variable) if instance_variable_defined?(instance_variable)
      return if notes.blank?

      parsed_notes(notes:, keys: [key.to_s])[key.to_s]
    end

    def observe_source!(observed_at: Time.current)
      @explicit_observed_at = observed_at
      capture_source_identity(observed_at:)
      save! if changed?
      self
    ensure
      @explicit_observed_at = nil
    end

    def mapping_provenance_with(other_item)
      target_sync_key = :"#{other_item.service_key}_id"
      source_sync_key = :"#{service_key}_id"

      if sync_ids_match?(sync_note_value_for(target_sync_key), other_item.external_id)
        {
          method: "source_sync_id",
          confidence: "high",
          metadata: {
            "matched_by" => "source_note",
            "note_key" => target_sync_key.to_s
          }
        }
      elsif sync_ids_match?(other_item.sync_note_value_for(source_sync_key), external_id)
        {
          method: "source_sync_id",
          confidence: "high",
          metadata: {
            "matched_by" => "target_note",
            "note_key" => source_sync_key.to_s
          }
        }
      elsif friendly_title_matches(other_item)
        {
          method: "title_fallback",
          confidence: "medium",
          metadata: {
            "matched_by" => "title",
            "title" => friendly_title
          }
        }
      else
        {
          method: "manual_backfill",
          confidence: "low",
          metadata: {}
        }
      end
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

      def find_by_source(service_name:, external_id:)
        normalized_service_name = Base::Service.normalized_service_name(service_name)
        find_by(source_service_name: normalized_service_name, external_id:) ||
          legacy_item_for_source(normalized_service_name:, external_id:)
      end

      def find_or_initialize_by_source(service_name:, external_id:)
        find_by_source(service_name:, external_id:) || new(
          external_id:,
          source_service_name: Base::Service.normalized_service_name(service_name)
        )
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
          external_data.fetch(attribute) { external_data.fetch(attribute.to_s) { external_data.fetch(attribute.to_sym, nil) } }
        elsif external_data.respond_to?(attribute.to_sym)
          external_data.send(attribute.to_sym)
        end
        value = value.get if value.respond_to?(:get)
        value == :missing_value ? nil : value
      rescue Appscript::CommandError => e
        # Stale AppleScript references (e.g., OSERROR -1728 "Can't get reference")
        # occur when a task is deleted mid-iteration. Return nil to keep the sync
        # run from crashing.
        raise unless stale_applescript_reference?(e)

        nil
      end

      def attribute_map
        raise "not implemented in #{self.class}"
      end

      private

      def stale_applescript_reference?(error)
        return true if error.respond_to?(:to_i) && error.to_i == -1728

        real_error = error.instance_variable_get(:@real_error) if error.instance_variable_defined?(:@real_error)
        return true if real_error.respond_to?(:to_i) && real_error.to_i == -1728

        error.message.include?("Can't get reference")
      end

      def standard_attribute_map
        # NOTE: Do not map `created_at` itself here. AR manages `created_at` /
        # `updated_at` as record timestamps. Persist the remote creation time in
        # `source_created_at` instead so local audit timestamps keep their
        # Rails semantics.
        {
          external_id: "id",
          completed_at: "completed_at",
          completed: "completed",
          due_at: "due_at",
          due_date: "due_date",
          flagged: "flagged",
          notes: "notes",
          source_created_at: "created_at",
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
        %i[completed_at last_modified source_created_at]
      end

      def legacy_item_for_source(normalized_service_name:, external_id:)
        where(source_service_name: nil, external_id:)
          .find { |item| inferred_service_name_for(item) == normalized_service_name }
      end

      def inferred_service_name_for(item)
        service_type = item.source_service_type.presence || item.provider
        base_identifier = Base::Service.service_identifier_for(service_type)
        matching_key = peer_sync_id_keys_for(item).find { |key| key.start_with?(base_identifier) }
        return service_type if matching_key.nil?

        instance_suffix = matching_key.delete_prefix(base_identifier).delete_suffix("_id").delete_prefix("_")
        [service_type, instance_suffix.presence].compact.join(":")
      end

      def peer_sync_id_keys_for(item)
        return [] if item.sync_collection_id.blank?

        Base::SyncItem.where(sync_collection_id: item.sync_collection_id)
                      .where.not(id: item.id)
                      .pluck(:notes)
                      .flat_map do |notes|
          notes.to_s.scan(/^([a-z0-9_]+_id):\s(.+)$/).filter_map do |key, value|
            key if value == item.external_id.to_s
          end
        end
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

      public :inferred_service_name_for
    end

    private

    def all_services(remove_current: false)
      all_services = (Array(options[:services]) + [options[:primary]]).map do |service|
        Base::Service.normalized_service_name(service)
      end
      all_services.delete(service_name) if remove_current
      all_services
    end

    def all_service_keys
      all_services(remove_current: true).flat_map do |service|
        service_key = Base::Service.service_identifier_for(service)
        ["#{service_key}_id", "#{service_key}_url"]
      end
    end

    def sync_id_values
      values = {}
      all_services(remove_current: true).each do |service|
        service_key = Base::Service.service_identifier_for(service)
        values["#{service_key}_id"] = instance_variable_get(:"@#{service_key}_id")
        values["#{service_key}_url"] = instance_variable_get(:"@#{service_key}_url")
      end
      values.compact
    end

    def sync_note_keys(raw_notes)
      (all_service_keys + discovered_sync_note_keys(raw_notes)).uniq
    end

    def discovered_sync_note_keys(raw_notes)
      raw_notes.to_s.scan(/^([a-z0-9_]+_(?:id|url)):\s/m).flatten
    end

    def set_tags
      @tags = default_tags
    end

    def default_tags
      options[:tags] + [service_name]
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

    def sync_ids_match?(left, right)
      return false if left.blank? || right.blank?

      left.to_s == right.to_s
    end

    def normalize_external_timestamp(value)
      return if value.blank?
      return value.in_time_zone if value.respond_to?(:in_time_zone)
      return Time.zone.at(value) if value.is_a?(Numeric)

      Time.zone.parse(value.to_s)
    end

    def capture_source_identity(observed_at: @explicit_observed_at || Time.current)
      resolved_service_name = Base::Service.normalized_service_name(
        source_service_name.presence || @service_name.presence || options[:service_name].presence || provider
      )

      self.source_service_name = resolved_service_name
      self.source_service_instance = Base::Service.instance_name_for(resolved_service_name)
      self.source_service_type = provider.presence || self.class.name.deconstantize
      self.source_external_id = external_id if external_id.present?
      self.source_url = url if url.present?
      self.source_updated_at = last_modified if last_modified.present?
      self.first_observed_at ||= observed_at
      self.last_observed_at = observed_at
      self.source_metadata ||= {}
    end
  end
end
