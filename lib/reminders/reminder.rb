# frozen_string_literal: true

require_relative "../base/sync_item"

module Reminders
  # A representation of an Reminders reminder
  class Reminder < Base::SyncItem
    attr_reader :list, :notes, :priority

    def initialize(reminder:, options:)
      super(sync_item: reminder, options:)
      containing_list = read_attribute(reminder, :container)
      @list = if containing_list.respond_to?(:get)
        containing_list.name.get
      else
        ""
      end
      @notes = read_attribute(reminder, :body)
      # TODO: Tags seem to be an OS-wide feature? It's not in the
      # AppleScript dictionary in macOS 13.1
      # @tags = read_attribute(reminder, :tags)
      # @tags = @tags.map { |tag| read_attribute(tag, :name) } unless @tags.nil?
      @priority = read_attribute(reminder, :priority)
      # Same with subtasks/subreminders - they are supported in the app
      # but don't seem to be accessible via Applescript
      # @subreminders = read_attribute(reminder, :reminders).map do |subreminder|
      #   reminder.new(subreminder, @options)
      # end
      # @subreminder_count = @subreminders.count
    end

    def attribute_map
      {
        id: "id_",
        title: "name",
        start_date: "remind_me_date",
        due_on: "allday_due_date",
        updated_at: "modification_date"
      }
    end

    def provider
      "Reminders"
    end

    def completed?; end

    def incomplete?; end

    def original_reminder; end
    memo_wise :original_reminder

    def friendly_title
      title
    end

    def to_s
      "#{provider}::Reminder:(#{id})#{title}"
    end

    # start_at is a "premium" feature, apparently
    def to_asana
      {
        completed:,
        due_at: due_date&.iso8601,
        liked: flagged,
        name: title,
        notes:
        # start_at: start_date&.iso8601
      }.compact
    end

    # https://github.com/googleapis/google-api-ruby-client/blob/main/google-api-client/generated/google/apis/tasks_v1/classes.rb#L26
    def to_google(with_due: false, skip_reclaim: false)
      # using to_date since GoogleTasks doesn't seem to care about the time (for due date)
      # and the exact time probably doesn't matter for completed
      google_task = with_due ? { due: due_date&.to_date&.rfc3339 } : {}
      google_task.merge(
        {
          completed: completion_date&.to_date&.rfc3339,
          notes:,
          status: completed ? "completed" : "needsAction",
          title: title + Reclaim::Task.title_addon(self, skip: skip_reclaim)
        }
      ).compact
    end

    def to_omnifocus(*)
      {
        name: friendly_title,
        note: notes,
        flagged:,
        completion_date:,
        defer_date: start_date,
        due_date: due_date || due_on
      }.compact
    end
    memo_wise :to_omnifocus
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