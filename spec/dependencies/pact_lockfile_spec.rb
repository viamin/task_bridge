# frozen_string_literal: true

require "spec_helper"
require "bundler"
require "yaml"

RSpec.describe "the Pact dependency lockfile" do
  macos_platforms = %w[arm64-darwin x86_64-darwin].freeze

  let(:gemfile) { File.read("Gemfile") }
  let(:lockfile) { Bundler::LockfileParser.new(File.read("Gemfile.lock")) }
  let(:rspec_runner) do
    YAML.safe_load_file(".github/workflows/test.yml").fetch("jobs").fetch("rspec").fetch("runs-on")
  end
  let(:pact_spec) { lockfile.specs.find { |spec| spec.name == "pact" } }
  let(:pact_ffi_specs) { lockfile.specs.select { |spec| spec.name == "pact-ffi" } }
  let(:pact_ffi_builds) do
    pact_ffi_specs.map(&:full_name)
  end
  let(:pact_ffi_version) { pact_ffi_specs.first.version.to_s }

  it "locks Pact's native FFI dependency" do
    expect(pact_ffi_specs).not_to be_empty
  end

  it "satisfies Pact's native FFI version requirement" do
    expect(pact_spec).not_to be_nil
    pact_ffi_dependency = pact_spec.dependencies.find { |dependency| dependency.name == "pact-ffi" }
    expect(pact_ffi_dependency).not_to be_nil

    expect(pact_ffi_specs.map(&:version)).to all(satisfy do |version|
      pact_ffi_dependency.requirement.satisfied_by?(version)
    end)
  end

  it "uses platform-specific native FFI packages" do
    expect(pact_ffi_specs.map { |spec| spec.platform.to_s }).not_to include("ruby")
  end

  it "locks the upgraded Pact release" do
    expect(pact_spec).not_to be_nil
    expect(pact_spec.version.to_s).to eq("2.1.2")
  end

  it "declares the Pact 2 release line" do
    expect(gemfile).to match(/^  gem "pact", "~> 2\.1", require: false(?:\s+#.*)?$/)
  end

  it "uses the same native FFI version for every locked platform" do
    versions = pact_ffi_specs.map { |spec| spec.version.to_s }.uniq

    expect(versions).to contain_exactly(pact_ffi_version)
  end

  it "associates every native Pact FFI package with a locked platform" do
    platforms = lockfile.platforms.map(&:to_s)
    ffi_platforms = pact_ffi_specs.map { |spec| spec.platform.to_s }

    expect(platforms).to include(*ffi_platforms)
  end

  it "locks Pact FFI builds compatible with the RSpec CI runner" do
    platforms = lockfile.platforms.map(&:to_s)
    expected_ffi_builds = macos_platforms.map { |platform| "pact-ffi-#{pact_ffi_version}-#{platform}" }

    aggregate_failures do
      expect(rspec_runner).to eq("macos-latest")
      expect(platforms).to include(*macos_platforms)
      expect(pact_ffi_builds).to include(*expected_ffi_builds)
    end
  end
end
