#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
Bundler.require(:default)
require_relative "lib/omnifocus/service"
require_relative "lib/google_tasks/service"
require_relative "lib/github/service"

class TaskBridge
  SUPPORTED_SERVICES = ["GoogleTasks", "Github"].freeze

  def initialize
    @options = Optimist.options do
      banner "Sync Tasks from one service to another"
      banner "Supported services: #{SUPPORTED_SERVICES.join(", ")}"
      banner "By default, tasks found with the tags in --tags will have a work context"
      opt :primary, "Primary task service", default: "Omnifocus"
      opt :tags, "Tags (or labels) to sync", default: ["TaskBridge"]
      opt :personal_tags, "Tags (or labels) used for personal context", default: ["Personal"]
      opt :work_tags, "Tags (or labels) used for work context (overrides personal tags)", type: :strings
      conflicts :personal_tags, :work_tags
      opt :services, "Services to sync tasks to", default: ["GoogleTasks"]
      opt :list, "Task list name to sync to", default: "🗓 Reclaim"
      opt :delete, "Delete completed tasks on service", default: false
      # opt :two_way, "Sync completion state back to task service", default: false
      opt :repositories, "Github repositories to check for synced issues", type: :strings
      opt :pretend, "List the found tasks, don't sync", default: false
      opt :verbose, "Verbose output", default: false
      opt :debug, "Print debug output", default: false
      opt :testing, "Use test path", default: false
    end
    Optimist.die :services, "Supported services: #{SUPPORTED_SERVICES.join(", ")}" if (SUPPORTED_SERVICES & @options[:services]).empty?
    @primary_service = "#{@options[:primary]}::Service".safe_constantize.new(@options)
  end

  def call
    puts @options.pretty_inspect if @options[:verbose]
    return testing if @options[:testing]
    return render if @options[:pretend]

    service_classes = @options[:services].map { |s| "#{s}::Service".safe_constantize }
    service_classes.each do |service_class|
      service = service_class.new(@options)
      if @options[:delete]
        service.prune
      else
        service.sync(@primary_service)
      end
    end
  end

  private

  def console
    of = @primary_service
    binding.pry # rubocop:disable Lint/Debugger
  end

  def render
    @primary_service.tasks_to_sync.each(&:render)
  end

  def testing
    service = Github::Service.new(@options)
    issues = service.send(:issues_to_sync)
    binding.pry
  end
end

TaskBridge.new.call
