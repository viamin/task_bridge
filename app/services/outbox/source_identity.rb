# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation, mapping, and
  # item rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be parsed
  # by splitting on `:` because segments may themselves contain colons.
  module SourceIdentity
    module_function

    # service_instance is embedded in idempotency keys and must stay stable
    # forever (#222), so single-instance services (no configured instance
    # suffix) get this permanent default token rather than a bare
    # service_type, matching the RDR's own examples (`asana:default`,
    # `omnifocus:default`). Backfilled and live rows must agree on this
    # token so they resolve to the same identity.
    DEFAULT_INSTANCE_SEGMENT = "default"

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)
      instance_segment = item.source_service_instance.presence || DEFAULT_INSTANCE_SEGMENT

      {
        service_type:,
        service_instance: [service_type, instance_segment].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
