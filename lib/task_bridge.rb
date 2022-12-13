#!/usr/bin/env ruby
# frozen_string_literal: true

require "rubygems"
require "bundler/setup"
Bundler.require(:default)
require_relative "debug"
require_relative "omnifocus/service"
require_relative "google_tasks/service"
require_relative "github/service"
require_relative "instapaper/service"
require_relative "reclaim/service"
require_relative "asana/service"

class TaskBridge
  def initialize
    supported_services = TaskBridge.supported_services
    @options = Optimist.options do
      banner "Sync Tasks from one service to another"
      banner "Supported services: #{supported_services.join(', ')}"
      banner "By default, tasks found with the tags in --tags will have a work context"
      opt :primary, "Primary task service", default: ENV.fetch("PRIMARY_TASK_SERVICE", "Omnifocus")
      opt :tags, "Tags (or labels) to sync", default: ENV.fetch("SYNC_TAGS", "TaskBridge").split(",")
      opt :personal_tags,
          "Tags (or labels) used for personal context",
          default: ENV.fetch("PERSONAL_TAGS", nil)
      opt :work_tags,
          "Tags (or labels) used for work context (overrides personal tags)",
          type: :strings,
          default: ENV.fetch("WORK_TAGS", nil)
      conflicts :personal_tags, :work_tags
      opt :services, "Services to sync tasks to", default: ENV.fetch("SYNC_SERVICES", "GoogleTasks,Github").split(",")
      opt :list, "Task list name to sync to", default: ENV.fetch("GOOGLE_TASKS_LIST", "My Tasks")
      opt :repositories, "Github repositories to sync from", default: ENV.fetch("GITHUB_REPOSITORIES", []).split(",")
      opt :max_age, "Skip syncing asks that have not been modified within this time (0 to disable)", default: ENV.fetch("SYNC_MAX_AGE", 0).to_i
      opt :delete,
          "Delete completed tasks on service",
          default: %w[true t yes 1].include?(ENV.fetch("DELETE_COMPLETED", "false").downcase)
      opt :only_from_primary, "Only sync FROM the primary service", default: false
      opt :only_to_primary, "Only sync TO the primary service", default: false
      conflicts :only_from_primary, :only_to_primary
      opt :pretend, "List the found tasks, don't sync", default: false
      opt :quiet, "No output - used for daemonized processes", default: false
      opt :verbose, "Verbose output", default: false
      conflicts :quiet, :verbose
      opt :debug, "Print debug output", default: false
      opt :console, "Run live console session", default: false
      opt :history, "Print sync service history", default: false
      opt :testing, "For testing purposes only", default: false
    end
    unless supported_services.intersect?(@options[:services])
      Optimist.die :services,
                   "Supported services: #{supported_services.join(', ')}"
    end
    @options[:max_age_timestamp] = (@options[:max_age]).zero? ? nil : Chronic.parse("#{@options[:max_age]} ago")
    @options[:uses_personal_tags] = @options[:work_tags].nil?
    @options[:sync_started_at] = Time.now.strftime("%Y-%m-%d %I:%M%p")
    @primary_service = "#{@options[:primary]}::Service".safe_constantize.new(@options)
    @services = @options[:services].to_h { |s| [s, "#{s}::Service".safe_constantize.new(@options)] }
  end

  def call
    start_time = Time.now
    puts "Starting sync at #{@options[:sync_started_at]}" unless @options[:quiet]
    puts @options.pretty_inspect if @options[:debug]
    return print_logs if @options[:history]
    return testing if @options[:testing]
    return console if @options[:console]

    @service_logs = []
    @services.each do |service_name, service|
      if service.nil?
        @service_logs << { service: service_name, last_attempted: @options[:sync_started_at] }
      elsif @options[:delete]
        service.prune
      elsif @options[:only_to_primary] && service.respond_to?(:sync_to_primary)
        @service_logs << service.sync_to_primary(@primary_service)
      elsif @options[:only_from_primary] && service.respond_to?(:sync_from_primary)
        @service_logs << service.sync_from_primary(@primary_service)
      elsif service.respond_to?(:sync_with_primary)
        # if the #sync_with_primary method exists, we should use it unless options force us not to
        @service_logs << service.sync_with_primary(@primary_service)
      else
        # Generally we should sync FROM the primary service first, since it should be the source of truth
        # and we want to avoid overwriting anything in the primary service if a duplicate task exists
        @service_logs << service.sync_from_primary(@primary_service) if service.respond_to?(:sync_from_primary)
        @service_logs << service.sync_to_primary(@primary_service) if service.respond_to?(:sync_to_primary)
      end
    end
    save_service_log!
    return if @options[:quiet]

    end_time = Time.now
    puts "Sync took #{end_time - start_time} seconds"
    puts "Finished sync at #{end_time.strftime('%Y-%m-%d %I:%M%p')}"
  end

  class << self
    def supported_services
      (provider_services + task_services).uniq
    end

    # These services provide items that become tasks in the primary service
    def provider_services
      %w[Github Instapaper Asana]
    end

    # These are services that have tasks or task-like objects
    # that should be kept in sync with the primary service
    def task_services
      %w[Asana GoogleTasks Omnifocus Reclaim]
    end
  end

  private

  def console
    binding.pry # rubocop:disable Lint/Debugger
  end

  def testing
    # add code to test here
  end

  def print_logs
    log_file = File.expand_path(File.join(__dir__, "..", "log", ENV.fetch("LOG_FILE", "service_sync.log")))
    return unless File.exist?(log_file)

    existing_logs = JSON.parse(File.read(log_file))
    space_needed = @services.keys.map(&:length).max
    puts format("%-#{space_needed}s |   Last Attempted    |   Last Successful   | Items Synced", "Service")
    existing_logs.each do |log_hash|
      puts format("%-#{space_needed}s | %18s | %18s | %d", log_hash["service"], log_hash["last_attempted"] || "", log_hash["last_successful"] || "", log_hash["items_synced"] || 0)
    end
  end

  def save_service_log!
    return if @service_logs.nil?

    log_file = File.expand_path(File.join(__dir__, "..", "log", ENV.fetch("LOG_FILE", "service_sync.log")))
    existing_logs = File.exist?(log_file) ? JSON.parse(File.read(log_file)) : []
    output = @service_logs.map do |service_log|
      existing_index = existing_logs.find_index { |hash| hash["service"] == service_log["service"] }
      if existing_index
        service_log.reverse_merge(existing_logs.delete_at(existing_index))
      else
        service_log
      end
    end
    output += existing_logs
    output.sort_by { |a, b| a["service"] <=> b["service"] }
    File.write(log_file, output.to_json)
  end
end
