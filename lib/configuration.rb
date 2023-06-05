# frozen_string_literal: true

class Configuration
  delegate_missing_to :@options

  def initialize(options)
    @options = OpenStruct.new(options)
  end
end
