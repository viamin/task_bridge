# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe StructuredLogger do
  let(:log_file) { "structured_logger_spec.json" }
  let(:log_path) { File.expand_path("../../log/#{log_file}", __dir__) }
  let(:options) do
    {
      services: %w[Asana Github],
      log_file: log_file,
      sync_started_at: "2024-01-01 09:00AM"
    }
  end
  let(:logger) { described_class.new(options) }

  after do
    FileUtils.rm_f(log_path)
  end

  describe "#summarize_service_run" do
    context "when the service run succeeds" do
      let(:logs) do
        [
          {
            "service" => "Asana",
            "last_attempted" => options[:sync_started_at],
            "last_successful" => options[:sync_started_at],
            "items_synced" => 3
          }
        ]
      end

      it "returns a success summary with processed items" do
        summary = logger.summarize_service_run(service_name: "Asana", logs:, default_detail: nil, error: nil)
        expect(summary[:status]).to eq("success")
        expect(summary[:items_synced]).to eq(3)
        expect(summary[:detail]).to include("3 items processed")
      end
    end

    context "when the service run fails" do
      let(:logs) do
        [
          {
            "service" => "Github",
            "last_attempted" => options[:sync_started_at],
            "last_failed" => "2024-01-01 09:05AM",
            "error_class" => "RuntimeError",
            "error_message" => "boom",
            "items_synced" => 0,
            "status" => "failed"
          }
        ]
      end

      it "returns a failure summary with error information" do
        error = RuntimeError.new("boom")
        summary = logger.summarize_service_run(service_name: "Github", logs:, default_detail: nil, error:)
        expect(summary[:status]).to eq("failed")
        expect(summary[:detail]).to include("RuntimeError: boom")
        expect(summary[:last_failed]).to eq("2024-01-01 09:05AM")
      end
    end
  end

  describe "#print_run_summary" do
    it "prints a tabular summary of results" do
      summaries = [
        {
          service: "Asana",
          status: "success",
          items_synced: 2,
          last_successful: "2024-01-01 09:00AM",
          last_failed: "",
          detail: "2 items processed"
        }
      ]

      output = capture_stdout { logger.print_run_summary(summaries) }

      expect(output).to include("Sync summary @ #{options[:sync_started_at]}")
      expect(output).to match(/Service\s+\|\s+Status\s+\|\s+Items\s+\|\s+Last Success\s+\|\s+Last Failure\s+\|\s+Details/)
      expect(output).to match(/Asana\s+\|\s+success\s+\|\s+2\s+\|/)
      expect(output).to include("2 items processed")
    end
  end

  def capture_stdout
    previous_stdout = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = previous_stdout
  end
end
