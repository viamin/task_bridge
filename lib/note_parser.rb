# frozen_string_literal: true

module NoteParser
  # The NoteParser will be used in the notes field for services that don't support custom fields
  # which currently is all of them?
  # parsed_notes expects key value pairs of the form "key: value" on its own line
  def parsed_notes(key, notes)
    key_value_matcher = /\A(?<before>.*)(?:#{key}:\s(?<value>.+))\R(?<after>.*)\Z/m
    match_data = key_value_matcher.match(notes)
    return [nil, notes] if match_data.nil?

    value = match_data[:value]
    notes = "#{match_data[:before]}#{match_data[:after]}".squish
    [value, notes]
  end

  # This will serialize the key value pairs in the values hash
  # the format will be notes, followed by a balnk line, followed by
  # the key value pairs, each on their own line
  def notes_with_values(notes, values_hash = {})
    value_string = ""
    values_hash.each do |key, value|
      value_string += "\n#{key}: #{value}"
    end
    "#{notes.squish}\n#{value_string}\n"
  end
end
