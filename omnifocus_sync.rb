#!/bin/env ruby

require "dotenv/load"
require "rb-scpt"
require_relative "lib/omnifocus/omnifocus"
require_relative "lib/omnifocus/task"
require_relative "lib/google_tasks/tasks_service"

class OmnifocusSync
  def initialize
    @omnifocus = Omnifocus::Omnifocus.new
  end

  def render
    @omnifocus.today_tasks.each(&:render)
  end

  def sync_google_tasks(list)
    @google = GoogleTasks::TasksService.new
    binding.pry
    # @omnifocus.today_tasks.each do |task|
    #   @google.add_task(task)
    # end
  end

  def console
    of = @omnifocus
    binding.pry # rubocop:disable Lint/Debugger
  end
end

list = ARGV[0] || "Reclaim"
OmnifocusSync.new.sync_google_tasks(list)
