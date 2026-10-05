# frozen_string_literal: true

namespace :task_bridge do
  desc "Publish read-only Google Calendar availability observations"
  task sync_calendar: :environment do
    service = GoogleCalendar::Service.new
    count = service.sync
    puts "Observed #{count} Google Calendar events"
  rescue StandardError => e
    warn "Google Calendar ingestion failed: #{e.class} #{e.message}"
    exit 1
  end
end
