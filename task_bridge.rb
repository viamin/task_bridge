#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
Bundler.require(:default)
require_relative "lib/omnifocus/omnifocus"
require_relative "lib/omnifocus/task"
require_relative "lib/google_tasks/service"

class TaskBridge
  def initialize
    @omnifocus = Omnifocus::Omnifocus.new
  end

  def render
    @omnifocus.today_tasks.each(&:render)
  end

  def sync_google_tasks(list_title, silent = false)
    @google = GoogleTasks::Service.new
    tasklist = @google.tasks_service.list_tasklists.items.find { |list| list.title == list_title }
    task_titles = @google.tasks_service.list_tasks(tasklist.id).items.map(&:title)
    omnifocus_tasks = @omnifocus.today_tasks
    progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: omnifocus_tasks.length) unless silent
    omnifocus_tasks.each do |task|
      @google.add_task(tasklist, task) unless task_titles.include?(task.title)
      progressbar.increment unless silent
    end
    puts "Synced #{omnifocus_tasks.length} Omnifocus tasks to Google Tasks" unless silent
  end

  def console
    of = @omnifocus
    binding.pry # rubocop:disable Lint/Debugger
  end
end

list = ARGV[0] || "🗓 Reclaim"
TaskBridge.new.sync_google_tasks(list)
