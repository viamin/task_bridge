# frozen_string_literal: true

# Namespace for the RDR 215 publication contract implementation.
#
# CONTRACT_VERSION is the single source of truth for the v1 wire contract:
# every batch envelope and record payload carries it, and the publisher
# validates stored rows against it. Bump it here — and only here — when the
# contract moves to a new major version.
module Publication
  CONTRACT_VERSION = 1
end
