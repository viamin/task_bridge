# frozen_string_literal: true

require "spec_helper"
require "bundler"

RSpec.describe "the Pact dependency lockfile" do
  let(:lockfile) { Bundler::LockfileParser.new(File.read("Gemfile.lock")) }

  it "includes Pact FFI builds for GitHub's macOS runner architectures" do
    platforms = lockfile.platforms.map(&:to_s)

    expect(platforms).to include("arm64-darwin", "x86_64-darwin")
  end
end
