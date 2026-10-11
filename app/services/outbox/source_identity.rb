# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Permanent default segment for services configured without an instance
    # suffix (#222): `service_instance` is required on every item and
    # observation row and is embedded in idempotency keys, so single-instance
    # services (e.g. OmniFocus) publish as `<service_type>:default` forever.
    # The live pipeline shares this builder, so backfilled and live rows
    # agree on identity.
    DEFAULT_INSTANCE = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)
      instance = item.source_service_instance.presence || DEFAULT_INSTANCE

      {
        service_type:,
        service_instance: [service_type, instance].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
