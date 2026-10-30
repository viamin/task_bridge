# frozen_string_literal: true

# Consumer-side Pact RSpec support for the TaskBridge -> TaskBridge Web
# ingestion contract (issue #250, RDR #215).
#
# Pact 2 configures each consumer suite through `has_http_pact_between`.
# The contract spec supplies the consumer, provider, pact directory, and its
# ephemeral mock-server URL; see docs/pact-consumer-contract-testing.md and
# task-bridge-web#189.
require "pact/rspec"
