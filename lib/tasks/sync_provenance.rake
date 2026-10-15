# frozen_string_literal: true

require "optparse"

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    extend GlobalOptions

    overrides = options
    arguments = ARGV.drop_while { |argument| argument != "--" }.drop(1)
    OptionParser.new do |parser|
      parser.on("-x", "--pretend", "Preview the backfill without making changes") { overrides[:pretend] = true }
    end.parse!(arguments)
    self.options = overrides

    if Thread.current[:global_options]&.fetch(:pretend, false)
      SyncBackfill::Preview.run!
      next
    end

    SyncBackfill::SourceProvenance.run!
    SyncBackfill::Baseline.run!
  end
end
