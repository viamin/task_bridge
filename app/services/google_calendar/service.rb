# frozen_string_literal: true

require "digest"
require "google/apis/calendar_v3"

module GoogleCalendar
  # Read-only Google Calendar observation source. It has no task sync
  # strategies: calendar failures are intentionally isolated in the dedicated
  # rake task and no Calendar API mutation methods are called here.
  class Service
    include GoogleTasks::AuthorizationHelpers

    BUSY_ONLY = "busy_only"
    EVENT_DETAILS = "event_details"
    PRIVACY_MODES = [BUSY_ONLY, EVENT_DETAILS].freeze

    def initialize(options: nil, calendar_service: Google::Apis::CalendarV3::CalendarService.new, authorization: nil)
      @options = options || settings
      @calendar_service = calendar_service
      @calendar_service.authorization = authorization || user_credentials_for(Google::Apis::CalendarV3::AUTH_CALENDAR_READONLY)
    end

    def sync(observed_at: Time.current)
      calendar_ids.sum { |calendar_id| sync_calendar(calendar_id, observed_at:) }
    end

    private

    attr_reader :calendar_service, :options

    def sync_calendar(calendar_id, observed_at:)
      events_for(calendar_id).count do |event|
        publish(event, calendar_id:, observed_at:)
      end
    end

    def events_for(calendar_id)
      calendar_service.list_events(
        calendar_id,
        single_events: true,
        order_by: "startTime",
        show_deleted: true,
        time_min: window_start.iso8601,
        time_max: window_end.iso8601
      ).items || []
    end

    def publish(event, calendar_id:, observed_at:)
      payload = payload_for(event, calendar_id:, observed_at:)
      OutboxEntry.enqueue(
        record_kind: :observation,
        event_type: "snapshot_seen",
        service_type: "google_calendar",
        service_instance: calendar_id,
        external_id: event.id,
        observed_at:,
        source_updated_at: event.updated,
        idempotency_key: idempotency_key_for(payload),
        payload:
      )
      true
    end

    def payload_for(event, calendar_id:, observed_at:)
      payload = {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        event_type: "snapshot_seen",
        observed_at: timestamp(observed_at),
        fact_type: "calendar_event",
        calendar: { service_type: "google_calendar", calendar_id: },
        event: {
          id: event.id,
          status: event.status,
          cancelled: event.status == "cancelled",
          availability: event.transparency == "transparent" ? "free" : "busy",
          start_at: event_time(event.start),
          end_at: event_time(event.end),
          source_updated_at: timestamp(event.updated)
        }
      }
      payload[:event].merge!(event_details(event)) if event_details?
      payload
    end

    def event_details(event)
      {
        title: event.summary.presence,
        location: event.location.presence,
        attendee_response_statuses: Array(event.attendees).filter_map do |attendee|
          attendee.response_status if attendee.response_status.present?
        end
      }.compact
    end

    def idempotency_key_for(payload)
      event = payload.fetch(:event)
      # Observation time records when TaskBridge saw the fact, not a source
      # change. Excluding it makes repeated reads of an unchanged event a
      # no-op while any source fact (including privacy-mode projection) gets
      # its own deterministic publication.
      stable_payload = payload.deep_dup.except(:observed_at)
      digest = Digest::SHA256.hexdigest(stable_payload.to_json)
      ["tb:v1", "calendar", payload.dig(:calendar, :calendar_id), event.fetch(:id), digest].join(":")
    end

    def event_time(value)
      date_time = value&.date_time
      return timestamp(date_time) if date_time

      value&.date
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end

    def event_details?
      privacy_mode == EVENT_DETAILS
    end

    def privacy_mode
      mode = options.fetch(:privacy_mode, BUSY_ONLY).to_s
      return mode if PRIVACY_MODES.include?(mode)

      raise ArgumentError, "unsupported Google Calendar privacy_mode: #{mode}"
    end

    def calendar_ids
      Array(options[:calendar_ids]).compact_blank
    end

    def window_start
      Time.current - options.fetch(:lookback_days, 7).to_i.days
    end

    def window_end
      Time.current + options.fetch(:lookahead_days, 30).to_i.days
    end

    def settings
      Chamber.dig(:google, :calendar) || {}
    end
  end
end
