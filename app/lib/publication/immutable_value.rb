# frozen_string_literal: true

module Publication
  module ImmutableValue
    module_function

    def copy(value)
      case value
      when Array
        value.map { |item| copy(item) }.freeze
      when Hash
        value.each_with_object({}) do |(key, nested), duplicated|
          duplicated[copy(key)] = copy(nested)
        end.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end
  end
end
