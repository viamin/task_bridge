#!/bin/env ruby

require "rb-scpt"
require_relative "lib/omnifocus/omnifocus"
require_relative "lib/omnifocus/task"

class OmnifocusSync
  def initialize
    @omnifocus = Omnifocus::Omnifocus.new
  end

  def render
    @omnifocus.today_tasks.each(&:render)
  end

  def console
    of = @omnifocus
    binding.irb
  end
end

OmnifocusSync.new.render
