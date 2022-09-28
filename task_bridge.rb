#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
Bundler.require(:default)
require_relative "lib/omnifocus/omnifocus"
require_relative "lib/omnifocus/task"
require_relative "lib/google_tasks/service"

class TaskBridge
  SUPPORTED_SERVICES = ["GoogleTasks"].freeze

  def initialize
    @options = Optimist.options do
      banner "Sync Tasks from OmniFocus to another service"
      banner "Supported services: #{SUPPORTED_SERVICES.join(", ")}"
      banner "By default, tasks found with the tags in --tags will have a work context"
      opt :tags, "OmniFocus tags to sync", default: ["Reclaim"]
      opt :personal_tags, "OmniFocus tags used for personal context", default: ["Personal"]
      opt :work_tags, "OmniFocus tags used for work context (overrides personal tags)", type: :strings
      conflicts :personal_tags, :work_tags
      opt :services, "Services to sync OmniFocus tasks to", default: ["GoogleTasks"]
      opt :list, "Task list name to sync to", default: "🗓 Reclaim"
      opt :delete, "Delete completed tasks on service", default: false
      # opt :update_omnifocus, "Sync completion state back to Omnifocus", default: false
      opt :pretend, "List the found tasks, don't sync", default: false
      opt :verbose, "Verbose output", default: false
    end
    Optimist.die :services, "Supported services: #{SUPPORTED_SERVICES.join(", ")}" if (SUPPORTED_SERVICES & @options[:services]).empty?
    @omnifocus = Omnifocus::Omnifocus.new(@options)
  end

  def call
    puts @options.pretty_inspect if @options[:verbose]
    return render if @options[:pretend]

    if @options[:services].include?("GoogleTasks")
      service = GoogleTasks::Service.new(@options)
      if @options[:delete]
        service.prune_tasks
      else
        service.sync_tasks(@omnifocus.tasks_to_sync)
      end
    end
  end

  private

  def render
    @omnifocus.tasks_to_sync.each(&:render)
  end

  def console
    of = @omnifocus
    binding.pry # rubocop:disable Lint/Debugger
  end
end

TaskBridge.new.call
