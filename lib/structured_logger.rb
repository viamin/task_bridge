# frozen_string_literal: true

class StructuredLogger
  include Debug

  attr_reader :options

  def initialize(options)
    @options = options
    @log_file = File.expand_path(File.join(__dir__, "..", "log", options[:log_file]))
    @space_needed = options[:services].map(&:length).max + 1
    @existing_logs = if File.exist?(@log_file)
      JSON.parse(File.read(@log_file))
    else
      []
    end
  end

  def sync_data_for(service_name)
    debug("service_name: #{service_name}") if options[:debug]
    @existing_logs.find { |log_hash| log_hash["service"] == service_name }
  end

  def last_synced(service_name, interval: false)
    debug("service_name: #{service_name}, interval: #{interval}") if options[:debug]
    raw_sync_data = sync_data_for(service_name)
    return if raw_sync_data.nil?

    last_sync = Chronic.parse(raw_sync_data["last_successful"])
    if interval
      Time.now - last_sync
    else
      last_sync
    end
  end

  def print_logs
    puts format("%-#{@space_needed}s |   Last Attempted   |   Last Successful  | Items Synced", "Service")
    puts "#{'-' * @space_needed}-|#{'-' * 20}|#{'-' * 20}|#{'-' * 13}"
    @existing_logs.each do |log_hash|
      puts format("%-#{@space_needed}s | %18s | %18s | %12d", log_hash["service"], log_hash["last_attempted"] || "", log_hash["last_successful"] || "", log_hash["items_synced"] || 0) if options[:services].include?(log_hash["service"].delete(" "))
    end
  end

  def save_service_log!(service_logs)
    debug("service_logs.count: #{service_logs.count}") if options[:debug]
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
end
