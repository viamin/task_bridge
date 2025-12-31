# frozen_string_literal: true

module NoteParser
  # The NoteParser will be used in the notes field for services that don't support custom fields
  # which currently is all of them?
  # parsed_notes expects key value pairs of the form "key: value" on its own line
  def parsed_notes(notes:, keys: [])
    return {} if notes.nil?

    values = {}
    keys.each do |key|
      key_value_matcher = /(?:#{key}:\s(?<value>.+))(\R|\z)/
      match_data = key_value_matcher.match(notes)
      if match_data.nil?
        values[key] = nil
      else
        values[key] = match_data[:value].strip
        notes = notes.gsub(match_data[0].strip, "")
      end
    end
    values["notes"] = notes.strip
    values
  end

  # This will serialize the key value pairs in the values hash
  # the format will be notes, followed by a blank line, followed by
  # the key value pairs, each on their own line
  # If a key already exists in the notes, it will be replaced with the new value
  def notes_with_values(notes, values_hash = {})
    notes ||= ""
    # First, remove any existing occurrences of keys we're about to add
    # This prevents duplicate sync IDs from accumulating
    values_hash.each_key do |key|
      # Remove all existing occurrences of this key (handles duplicates)
      notes = notes.gsub(/^#{Regexp.escape(key.to_s)}:\s.*$\R?/, "")
    end
    # Strip trailing whitespace from notes before adding new values
    notes = notes.rstrip

    value_string = ""
    values_hash.each do |key, value|
      value_string += "\n#{key}: #{value}" unless value.nil?
    end
    "#{notes}\n#{value_string}".strip
  end
end
