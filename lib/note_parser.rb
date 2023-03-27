# frozen_string_literal: true

module NoteParser
  # The NoteParser will be used in the notes field for services that don't support custom fields
  # which currently is all of them?
  # parsed_notes expects key value pairs of the form "key: value" on its own line
  def parsed_notes(keys:, notes:)
    return if notes.nil?

    values = []
    keys.each do |key|
      key_value_matcher = /(?:#{key}:\s(?<value>.+))(\R|\z)/
      match_data = key_value_matcher.match(notes)
      if match_data.nil?
        values << nil
      else
        values << match_data[:value].strip
        notes = notes.split(match_data[0]).join
      end
    end
    values + [notes.strip]
  end

  # This will serialize the key value pairs in the values hash
  # the format will be notes, followed by a blank line, followed by
  # the key value pairs, each on their own line
  def notes_with_values(notes, values_hash = {})
    value_string = ""
    values_hash.each do |key, value|
      value_string += "\n#{key}: #{value}" unless value.nil?
    end
    "#{notes}\n#{value_string}\n"
  end
end
