# frozen_string_literal: true

# Central SimpleCov configuration.
# Run with: COVERAGE=1 bundle exec rspec
# Incrementally raise thresholds as test suite improves (see issue #127).

require "simplecov"

SimpleCov.start do
  enable_coverage :branch

  track_files "{lib,app}/**/*.rb"

  add_filter "/spec/"
  add_filter "/pkg/"
  add_filter "/tmp/"
  add_filter "/config/"
  add_filter "/db/"

  # Initial baseline; raise gradually.
  # minimum_coverage 70
  # minimum_coverage_by_file 40
  # refuse_coverage_drop temporarily disabled during Rails conversion
  # refuse_coverage_drop
end
