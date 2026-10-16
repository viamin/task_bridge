# frozen_string_literal: true

require "optparse"

namespace :task_bridge do
  desc "backfill sync provenance and TaskBridge Web baseline records"
  task backfill_sync_provenance: :environment do
    extend GlobalOptions

    previous_options = Thread.current[:global_options]
    overrides = options.dup
    arguments = ARGV.drop_while { |argument| argument != "--" }.drop(1)
    OptionParser.new do |parser|
      parser.on("-x", "--pretend", "Preview the backfill without making changes") { overrides[:pretend] = true }
    end.parse!(arguments)
    self.options = overrides
    if options[:pretend]
      SyncBackfill::Preview.run!
    else
      SyncBackfill::SourceProvenance.run!
      SyncBackfill::Baseline.run!
    end
  ensure
    Thread.current[:global_options] = previous_options
  end
end
