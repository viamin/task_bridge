# frozen_string_literal: true

require_relative "../base/sync_item"

module Reminders
  # A representation of an Reminders reminder
  class Reminder < Base::SyncItem
    attr_reader :list, :priority

    def initialize(reminder:, options:)
      super(sync_item: reminder, options:)
      containing_list = read_attribute(reminder, :container)
      @list = if containing_list.respond_to?(:get)
        containing_list.name.get
      else
        ""
      end
      # TODO: Tags seem to be an OS-wide feature? It's not in the
      # AppleScript dictionary in macOS 13.1
      # @tags = read_attribute(reminder, :tags)
      # @tags = @tags.map { |tag| read_attribute(tag, :name) } unless @tags.nil?
      @priority = read_attribute(reminder, :priority)
      # Same with sub_items/subreminders - they are supported in the app
      # but don't seem to be accessible via Applescript
      # @subreminders = read_attribute(reminder, :reminders).map do |subreminder|
      #   reminder.new(subreminder, @options)
      # end
      # @subreminder_count = @subreminders.count
    end

    def attribute_map
      {
        id: "id_",
        due_on: "allday_due_date",
        notes: "body",
        start_date: "remind_me_date",
        title: "name",
        updated_at: "modification_date",
        completed_on: "completion_date"
      }
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
      Service.new(options:).reminders_app.lists[list].reminders.ID(id)
    end
    memo_wise :original_reminder

    def friendly_title
      title
    end

    def sync_notes
      notes_with_values(notes, sync_id:)
    end

    def to_s
      "#{provider}::Reminder:(#{id})#{title}"
    end

    def update_attributes(attributes)
      attributes.each do |key, value|
        original_attribute_key = inverted_attributes[key]
        original_reminder.send(original_attribute_key.to_sym).set(value) if original_attribute_key
      end
    end

    private

    def project_map
      options[:reminders_mapping].split(",").to_h { |mapping| mapping.split("~") }
    end
    memo_wise :project_map
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
