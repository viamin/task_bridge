# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Instance segment for single-instance services (RDR #215 example:
    # `omnifocus:default`). Embedded in idempotency keys, so it is permanent
    # once published; the live pipeline and the backfill (#222) share it so
    # backfilled and live rows agree on identity.
    DEFAULT_INSTANCE = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)

      {
        service_type:,
        service_instance: [service_type, item.source_service_instance.presence || DEFAULT_INSTANCE].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
