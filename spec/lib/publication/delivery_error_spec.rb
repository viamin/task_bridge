# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::DeliveryError do
  it "exposes retryable" do
    err = described_class.new("oops", retryable: true)
    expect(err.retryable).to be true
  end

  it "defaults to a non-retryable classification when told so" do
    err = described_class.new("bad request", retryable: false)
    expect(err.retryable).to be false
  end

  it "is a StandardError" do
    expect(described_class.new("x", retryable: false)).to be_a(StandardError)
  end
end
