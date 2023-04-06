# frozen_string_literal: true

RSpec.shared_context "full_options", full_options: true do
  let(:options) { full_options }
  let(:full_options) do
    {
      tags:,
      services: service_names,
      primary: primary_service_name,
      personal_tags:,
      work_tags:,
      logger:
    }
  end
  let(:tags) { [] }
  let(:service_names) { %w[Asana Reminders Github GoogleTasks Reclaim Instapaper] }
  let(:primary_service_name) { "Omnifocus" }
  let(:logger) { double(StructuredLogger) }
  let(:personal_tags) { "Personal" }
  let(:work_tags) { "" }
end
