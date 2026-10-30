# frozen_string_literal: true

require "rails_helper"
require "pact_helper"

RSpec.describe PactJsonMatcherDeserializer do
  it "reifies Pact matchers without permitting arbitrary JSON additions" do
    matcher = Pact::Term.new(matcher: /\Avalue\z/, generate: "value")

    decoded = described_class.call(JSON.parse(JSON.dump(matcher)))

    expect(decoded).to be_a(Pact::Term)
    expect(decoded.generate).to eq("value")
    expect(decoded.matcher).to match("value")
  end

  it "leaves unknown json_class values as data" do
    decoded = described_class.call("json_class" => "Untrusted::Object", "value" => "safe")

    expect(decoded).to eq("json_class" => "Untrusted::Object", "value" => "safe")
  end
end
