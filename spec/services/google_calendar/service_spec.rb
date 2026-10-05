# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoogleCalendar::Service do
  let(:calendar_service) { instance_double(Google::Apis::CalendarV3::CalendarService, "authorization=": true) }
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:options) { { calendar_ids: ["work@example.com"], privacy_mode: privacy_mode, lookback_days: 7, lookahead_days: 30 } }
  let(:privacy_mode) { "busy_only" }
  let(:service) { described_class.new(options:, calendar_service:, authorization: {}) }
  let(:event) do
    instance_double(
      Google::Apis::CalendarV3::Event,
      id: "event-1", status: "confirmed", transparency: "opaque",
      start: Google::Apis::CalendarV3::EventDateTime.new(date_time: Time.zone.parse("2026-10-05T11:00:00Z")),
      end: Google::Apis::CalendarV3::EventDateTime.new(date_time: Time.zone.parse("2026-10-05T11:45:00Z")),
      updated: Time.zone.parse("2026-10-01T12:00:00Z"), summary: "Sensitive planning", location: "Office",
      attendees: [Google::Apis::CalendarV3::EventAttendee.new(response_status: "accepted")]
    )
  end

  before do
    allow(calendar_service).to receive(:list_events).and_return(double(items: [event], next_page_token: nil))
  end

  it "publishes busy availability without private event fields by default" do
    expect { service.sync(observed_at:) }.to change(OutboxEntry, :count).by(1)

    payload = OutboxEntry.last.payload
    expect(payload.dig("event", "availability")).to eq("busy")
    expect(payload.dig("event", "start_at")).to eq("2026-10-05T11:00:00.000000Z")
    expect(payload.dig("event", "title")).to be_nil
    expect(payload.dig("event", "location")).to be_nil
    expect(payload.dig("event", "attendee_response_statuses")).to be_nil
  end

  it "publishes explicitly enabled event details" do
    options[:privacy_mode] = "event_details"

    service.sync(observed_at:)

    expect(OutboxEntry.last.payload.dig("event", "title")).to eq("Sensitive planning")
  end

  it "is idempotent when the observed event has not changed" do
    service.sync(observed_at:)

    expect { service.sync(observed_at: observed_at + 1.hour) }.not_to change(OutboxEntry, :count)
  end

  it "publishes a new fact when the source update timestamp changes" do
    service.sync(observed_at:)
    allow(event).to receive(:updated).and_return(Time.zone.parse("2026-10-02T12:00:00Z"))

    expect { service.sync(observed_at: observed_at + 1.hour) }.to change(OutboxEntry, :count).by(1)
  end

  it "keeps cancelled events as deterministic cancelled facts" do
    allow(event).to receive(:status).and_return("cancelled")

    service.sync(observed_at:)

    expect(OutboxEntry.last.payload.dig("event", "cancelled")).to be(true)
  end

  it "publishes events from every response page" do
    next_event = Google::Apis::CalendarV3::Event.new(
      id: "event-2", status: "confirmed", transparency: "opaque",
      start: Google::Apis::CalendarV3::EventDateTime.new(date_time: Time.zone.parse("2026-10-05T12:00:00Z")),
      end: Google::Apis::CalendarV3::EventDateTime.new(date_time: Time.zone.parse("2026-10-05T12:45:00Z")),
      updated: Time.zone.parse("2026-10-01T12:00:00Z")
    )
    allow(calendar_service).to receive(:list_events).and_return(
      double(items: [event], next_page_token: "next-page"),
      double(items: [next_event], next_page_token: nil)
    )

    expect { service.sync(observed_at:) }.to change(OutboxEntry, :count).by(2)
    expect(calendar_service).to have_received(:list_events).with("work@example.com", hash_including(page_token: "next-page"))
  end
end
