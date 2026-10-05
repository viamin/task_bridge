# frozen_string_literal: true

module Disappearance
  # The tombstone observation states for source representations TaskBridge
  # can no longer see (#220, expressed in RDR #215 terms). A state says why
  # the representation vanished from TaskBridge's view; it never claims more
  # than the source semantics can prove.
  module States
    # The source states the item was destroyed (e.g. an API 404 on direct
    # lookup, or absence from a complete full-list fetch).
    SOURCE_DELETED = "source_deleted"
    # The source moved the item out of the active universe (e.g. Asana's
    # archived flag). Reversible, so this is not SOURCE_DELETED.
    SOURCE_ARCHIVED = "source_archived"
    # The item left the range of what the source returns to TaskBridge
    # (moved list/project, cleared from a list) but was not verifiably
    # destroyed.
    NO_LONGER_VISIBLE = "no_longer_visible"
    # The item verifiably still exists in the source but no longer matches
    # the query TaskBridge uses (e.g. an OmniFocus task that lost its sync
    # tag).
    NO_LONGER_MATCHES_QUERY = "no_longer_matches_query"
    # Reserved for consumers classifying runs where TaskBridge could only
    # perform a partial fetch. The detector never emits this state: absence
    # from a partial fetch proves nothing, so TaskBridge records nothing
    # rather than a low-confidence guess.
    POSSIBLY_MISSING_AFTER_PARTIAL_SYNC = "possibly_missing_after_partial_sync"

    ALL = [
      SOURCE_DELETED,
      SOURCE_ARCHIVED,
      NO_LONGER_VISIBLE,
      NO_LONGER_MATCHES_QUERY,
      POSSIBLY_MISSING_AFTER_PARTIAL_SYNC
    ].freeze

    # States that mean the representation is gone from the source itself
    # (rather than just from TaskBridge's query results). Only a proven
    # destruction sets `is_deleted` on a tombstone: archived is reversible.
    DELETION_STATES = [SOURCE_DELETED].freeze

    def self.deletion?(state)
      DELETION_STATES.include?(state)
    end
  end
end
