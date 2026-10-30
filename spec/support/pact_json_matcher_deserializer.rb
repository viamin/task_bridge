# frozen_string_literal: true

# json 3 no longer reifies arbitrary objects from a `json_class` field. Pact
# 1.x uses that legacy representation to send matcher definitions to its mock
# service, so restore only the known matcher types at this test boundary.
module PactJsonMatcherDeserializer
  MATCHER_TYPES = %w[Pact::ArrayLike Pact::SomethingLike Pact::Term Regexp].freeze

  def self.call(value)
    case value
    when Array
      value.map { |element| call(element) }
    when Hash
      deserialize_hash(value)
    else
      value
    end
  end

  def self.deserialize_hash(value)
    return value.transform_values { |element| call(element) } unless MATCHER_TYPES.include?(value["json_class"])

    deserialize_matcher(value)
  end

  def self.deserialize_matcher(value)
    case value.fetch("json_class")
    when "Pact::ArrayLike"
      Pact::ArrayLike.new(call(value.fetch("contents")), min: value.fetch("min", 1))
    when "Pact::SomethingLike"
      Pact::SomethingLike.new(call(value.fetch("contents")))
    when "Pact::Term"
      data = value.fetch("data")
      Pact::Term.new(generate: call(data.fetch("generate")), matcher: call(data.fetch("matcher")))
    when "Regexp"
      Regexp.new(value.fetch("s"), value.fetch("o", 0))
    end
  end
end

module PactJsonLoadCompatibility
  def load(source, proc = nil, allow_blank: false, **options)
    PactJsonMatcherDeserializer.call(super(source, proc, allow_blank:, **options))
  end
end

JSON.singleton_class.prepend(PactJsonLoadCompatibility)
