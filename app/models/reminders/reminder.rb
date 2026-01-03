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

module Reminders
  # A representation of an Reminders reminder
  class Reminder < Base::SyncItem
    attr_accessor :reminder
    attr_reader :list, :priority

    def read_original(only_modified_dates: false)
      super(only_modified_dates:)
      containing_list = read_attribute(reminder, :container, only_modified_dates:)
      @list = if containing_list.respond_to?(:get)
        containing_list.name.get
      else
        ""
      end
      # TODO: Tags seem to be an OS-wide feature? It's not in the
      # AppleScript dictionary in macOS 13.1
      # @tags = read_attribute(reminder, :tags)
      # @tags = @tags.map { |tag| read_attribute(tag, :name) } unless @tags.nil?
      @priority = read_attribute(reminder, :priority, only_modified_dates:)
      # Same with sub_items/subreminders - they are supported in the app
      # but don't seem to be accessible via Applescript
      # @subreminders = read_attribute(reminder, :reminders).map do |subreminder|
      #   reminder.new(subreminder)
      # end
      # @subreminder_count = @subreminders.count
      self
    end

    def external_data
      reminder
    end

    def project
      project_map[list]
    end

    def provider
      "Reminders"
    end

    def personal?
      true
    end

    def original_reminder
      Service.new(options:).reminders_app.lists[list].reminders.ID(external_id)
    end

    def external_sync_notes
      notes_with_values(notes, reminders_id: external_id)
    end

    def friendly_title
      title
    end

    def to_s
      "#{provider}::Reminder:(#{external_id})#{title}"
    end

    def update_attributes(attributes)
      attributes.each do |key, value|
        original_attribute_key = attribute_map[key].to_sym
        original_reminder.send(original_attribute_key).set(value)
      end
    end

    class << self
      def attribute_map
        {
          external_id: "id_",
          due_at: "allday_due_date",
          notes: "body",
          start_date: "remind_me_date",
          title: "name",
          last_modified: "modification_date",
          completed_on: "completion_date"
        }
      end
    end

    private

    def project_map
      options[:reminders_mapping].split(",").to_h { |mapping| mapping.split("~") }
    end
  end
end

# reminder.properties_.get
# {
#   :name=>"Test Reminder with all the fixings",
#   :completion_date=>:missing_value,
#   :container=>app("/System/Applications/Reminders.app").lists.ID("C7022FFA-A382-40E2-8C93-2329989A4679"),
#   :remind_me_date=>2022-12-23 22:00:00 -0800,
#   :completed=>false,
#   :priority=>5, #medium
#   :id_=>"x-apple-reminder://FC68B02B-7FEF-48C6-B05A-967DFF734E8A",
#   :creation_date=>2022-12-23 21:53:23 -0800,
#   :modification_date=>2022-12-23 21:54:19 -0800,
#   :flagged=>false,
#   :allday_due_date=>2022-12-23 00:00:00 -0800,
#   :body=>"This is a note",
#   :due_date=>2022-12-23 22:00:00 -0800
# }
