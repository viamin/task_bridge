# frozen_string_literal: true

class StructuredLogger
  include Debug
  include GlobalOptions

  HEADER_LABELS = {
    service: "Service",
    status: "Status",
    items: "Items",
    last_success: "Last Success",
    last_failure: "Last Failure",
    details: "Details"
  }.freeze
  HEADER_LENGTHS = HEADER_LABELS.transform_values(&:length).freeze

  attr_reader :options

  def initialize(options)
    @options = options
    @log_file = File.expand_path(Rails.root.join(options[:log_file]))
    @space_needed = options[:services].map(&:length).max + 1
    @existing_logs = if File.exist?(@log_file)
      JSON.parse(File.read(@log_file))
    else
      []
    end
  end

  def sync_data_for(service_name)
    debug("service_name: #{service_name}", options[:debug])
    @existing_logs.find { |log_hash| log_hash["service"] == service_name }
  end

  def last_synced(service_name, interval: false)
    debug("service_name: #{service_name}, interval: #{interval}", options[:debug])
    raw_sync_data = sync_data_for(service_name)
    return if raw_sync_data.nil?

    last_sync = Time.parse(raw_sync_data["last_successful"])
    if interval
      Time.now - last_sync
    else
      last_sync
    end
  end

  def print_logs
    puts format(
      "%-#{@space_needed}s |   Last Attempted   |   Last Successful  |   Last Failed     | Items Synced | Status",
      "Service"
    )
    puts "#{"-" * @space_needed}-|#{"-" * 20}|#{"-" * 20}|#{"-" * 20}|#{"-" * 13}|#{"-" * 8}"
    @existing_logs.each do |log_hash|
      next unless options[:services].include?(log_hash["service"].delete(" "))

      puts format(
        "%-#{@space_needed}s | %18s | %18s | %18s | %12d | %-6s",
        log_hash["service"],
        log_hash.fetch("last_attempted", ""),
        log_hash.fetch("last_successful", ""),
        log_hash.fetch("last_failed", ""),
        log_hash.fetch("items_synced", 0),
        status_for_log(log_hash)
      )
    end
  end

  def summarize_service_run(service_name:, logs:, default_detail: nil, error: nil)
    normalized_logs = Array(logs).compact
    items_synced = normalized_logs.sum { |entry| entry.fetch("items_synced", 0).to_i }
    last_attempted = pluck_last(normalized_logs, "last_attempted")
    last_successful = pluck_last(normalized_logs, "last_successful")
    last_failed = pluck_last(normalized_logs, "last_failed")
    detail = default_detail || pluck_last(normalized_logs, "detail")

    failed_entry = normalized_logs.reverse.find do |entry|
      entry["status"].to_s == "failed" || entry["error_message"].present?
    end
    status = if failed_entry || error
      "failed"
    elsif normalized_logs.any? { |entry| entry["status"].to_s == "success" || entry["last_successful"].present? }
      "success"
    elsif normalized_logs.any?
      "skipped"
    else
      "idle"
    end

    detail = detail.to_s.strip
    case status
    when "failed"
      failure_detail = failure_detail_from(failed_entry) || (error ? "#{error.class}: #{error.message}" : nil)
      failure_detail = "#{failure_detail} (#{last_failed})" if failure_detail && last_failed
      detail = [detail, failure_detail].reject(&:blank?).join(" — ")
      detail = "Failure recorded#{last_failed ? " (#{last_failed})" : ""}" if detail.blank?
    when "success"
      detail = items_synced.positive? ? "#{items_synced} items processed" : "No changes detected" if detail.blank?
    when "skipped"
      detail = detail.presence || "Sync not required"
    else
      detail = detail.presence || "No work performed"
    end

    {
      service: service_name,
      status: status,
      items_synced: items_synced,
      last_attempted: last_attempted,
      last_successful: last_successful,
      last_failed: last_failed,
      detail: detail
    }
  end

  def print_run_summary(run_summaries)
    summaries = Array(run_summaries).compact
    return if summaries.empty?

    service_width = [@space_needed, HEADER_LENGTHS[:service], summaries.map { |s| s[:service].to_s.length }.max].compact.max
    status_width = [HEADER_LENGTHS[:status], summaries.map { |s| s[:status].to_s.length }.max].compact.max
    items_width = [HEADER_LENGTHS[:items], summaries.map { |s| s[:items_synced].to_s.length }.max].compact.max
    success_width = [HEADER_LENGTHS[:last_success], summaries.map { |s| s[:last_successful].to_s.length }.max].compact.max
    failure_width = [HEADER_LENGTHS[:last_failure], summaries.map { |s| s[:last_failed].to_s.length }.max].compact.max
    detail_width = [HEADER_LENGTHS[:details], summaries.map { |s| s[:detail].to_s.length }.max].compact.max

    header_format = "%-#{service_width}s | %-#{status_width}s | %#{items_width}s | %-#{success_width}s | %-#{failure_width}s | %-#{detail_width}s"
    row_format = "%-#{service_width}s | %-#{status_width}s | %#{items_width}d | %-#{success_width}s | %-#{failure_width}s | %-#{detail_width}s"

    puts "Sync summary @ #{options[:sync_started_at]}"
    puts format(
      header_format,
      HEADER_LABELS[:service],
      HEADER_LABELS[:status],
      HEADER_LABELS[:items],
      HEADER_LABELS[:last_success],
      HEADER_LABELS[:last_failure],
      HEADER_LABELS[:details]
    )
    puts [
      "-" * service_width,
      "-" * status_width,
      "-" * items_width,
      "-" * success_width,
      "-" * failure_width,
      "-" * detail_width
    ].join("-+-")

    summaries.each do |summary|
      puts format(
        row_format,
        summary[:service],
        summary[:status],
        summary[:items_synced],
        summary[:last_successful].to_s,
        summary[:last_failed].to_s,
        summary[:detail].to_s
      )
    end
  end

  def save_service_log!(service_logs)
    debug("service_logs.count: #{service_logs.count}", options[:debug])
    return if service_logs.empty?

    output = service_logs.map do |service_log|
      existing_index = @existing_logs.find_index { |hash| hash["service"] == service_log["service"] }
      if existing_index
        service_log.reverse_merge(@existing_logs.delete_at(existing_index))
      else
        service_log
      end
    end
    output += @existing_logs
    output.sort_by! { |element| element["service"] }
    File.write(@log_file, output.to_json)
    @existing_logs = output
  end

  private

  def pluck_last(logs, key)
    logs.filter_map { |entry| entry[key] }.last
  end

  def status_for_log(log_hash)
    return log_hash["status"] if log_hash["status"].present?

    if log_hash["error_message"].present?
      "failed"
    elsif log_hash["last_successful"].present?
      "success"
    elsif log_hash["last_attempted"].present?
      "skipped"
    else
      "unknown"
    end
  end

  def failure_detail_from(log_hash)
    return unless log_hash

    parts = []
    parts << log_hash["error_class"] if log_hash["error_class"].present?
    parts << log_hash["error_message"] if log_hash["error_message"].present?
    parts.presence&.join(": ")
  end
end
