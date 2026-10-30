# frozen_string_literal: true

require "spec_helper"
require "bundler"

RSpec.describe "the Pact dependency lockfile" do
  macos_platforms = %w[arm64-darwin x86_64-darwin].freeze

  let(:lockfile) { Bundler::LockfileParser.new(File.read("Gemfile.lock")) }
  let(:pact_ffi_specs) { lockfile.specs.select { |spec| spec.name == "pact-ffi" } }
  let(:pact_ffi_builds) do
    pact_ffi_specs.map(&:full_name)
  end
  let(:pact_ffi_version) { pact_ffi_specs.first.version.to_s }

  it "locks Pact's native FFI dependency" do
    expect(pact_ffi_specs).not_to be_empty
  end

  it "includes Pact FFI builds for GitHub's macOS runner architectures" do
    platforms = lockfile.platforms.map(&:to_s)

    expect(platforms).to include(*macos_platforms)
  end

  it "locks the native Pact FFI packages for GitHub's macOS runner architectures" do
    expect(pact_ffi_builds).to include(
      *macos_platforms.map { |platform| "pact-ffi-#{pact_ffi_version}-#{platform}" }
    )
  end
end
