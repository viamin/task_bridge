# frozen_string_literal: true

module Github
  # Publishes selected GitHub timeline and review facts as item-scoped outbox
  # observations. GitHub's item `updated_at` tells us which items merit a
  # lookup, while the source event ID is the stable identity of each fact.
  class ActivityEmitter
    # The timeline endpoint reports state changes but has no event for the
    # initial opening, so the `opened` activity is derived separately from
    # the issue/PR response (see #opened_activity).
    EVENT_TYPES = {
      "commented" => "comment_added",
      "labeled" => "label_added",
      "unlabeled" => "label_removed",
      "assigned" => "assigned",
      "unassigned" => "unassigned",
      "closed" => "closed",
      "reopened" => "reopened",
      "merged" => "merged",
      "renamed" => "title_changed",
      "milestoned" => "milestone_changed",
      "demilestoned" => "milestone_changed"
    }.freeze

    def self.emit_for(item, events:, since:)
      new(item, events:, since:).emit
    end

    def initialize(item, events:, since:)
      @item = item
      @events = events
      @since = since
    end

    def emit
      return false if item.options[:pretend]

      [opened_activity, *meaningful_events].compact.all? { |activity| enqueue(activity) }
    end

    private

    attr_reader :item, :events, :since

    # The issue/PR response is the only source for the opening fact: derive an
    # activity from its `created_at` keyed by the stable issue ID.
    def opened_activity
      response = item.external_data
      return if response.blank? || response["id"].blank? || response["created_at"].blank?

      issue_id = response["id"]
      activity = {
        type: "opened",
        source_event_id: "#{issue_id}-opened",
        occurred_at: response["created_at"],
        actor: response.dig("user", "login")
      }.compact
      recent?(activity) ? activity : nil
    end

    def meaningful_events
      events.filter_map { |event| activity_for(event) }.select { |activity| recent?(activity) }
    end

    def activity_for(event)
      type = event["activity_type"] || EVENT_TYPES[event["event"]]
      return if type.blank? || event["id"].blank? || occurred_at(event).blank?

      {
        type:,
        source_event_id: event["id"].to_s,
        occurred_at: occurred_at(event),
        actor: event.dig("actor", "login") || event.dig("user", "login"),
        details: event_details(event)
      }.compact
    end

    def recent?(activity)
      since.blank? || Time.iso8601(activity[:occurred_at]) >= since
    end

    def enqueue(activity)
      identity = Outbox::SourceIdentity.for(item)
      # Outbox publication is bookkeeping around sync flows (#219): a failed
      # outbox write must never change the sync result that produced it. Wrap
      # the enqueue in Outbox::IsolatedWrite so a transient SQLite lock is
      # retried and reported instead of aborting the Github run, mirroring
      # Outbox::ObservationEmitter (#224). The wrapper returns the block's
      # value on success or nil once retries are exhausted; we treat nil as
      # a failure so callers can decide whether the activity-sync cursor
      # should advance.
      enqueued = Outbox::IsolatedWrite.call("github activity for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :observation,
          event_type: Outbox::ObservationEmitter::SOURCE_CHANGED,
          payload: payload_for(activity, identity),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          observed_at: Time.iso8601(activity[:occurred_at]),
          source_updated_at: Time.iso8601(activity[:occurred_at]),
          idempotency_key: activity_key(identity, activity)
        )
      end
      !enqueued.nil?
    end

    def payload_for(activity, identity)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        event_type: Outbox::ObservationEmitter::SOURCE_CHANGED,
        observed_at: activity[:occurred_at],
        item_key: item.item_key,
        source: identity,
        source_updated_at: activity[:occurred_at],
        activity: activity.compact,
        provenance: { detected_by: "github_timeline" }
      }
    end

    def activity_key(identity, activity)
      ["tb:v1", "obs", identity[:service_instance], identity[:external_id], "activity", activity[:source_event_id]].join(":")
    end

    def occurred_at(event)
      event["created_at"] || event["submitted_at"] || event["updated_at"]
    end

    def event_details(event)
      details = {
        label: event.dig("label", "name"),
        assignee: event.dig("assignee", "login"),
        milestone: event.dig("milestone", "title"),
        from: event.dig("rename", "from"),
        to: event.dig("rename", "to"),
        review_state: event["state"]
      }.compact
      details.presence
    end
  end
end
