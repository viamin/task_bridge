# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by item, observation, and
  # mapping rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be parsed
  # by splitting on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Permanent default instance segment for services configured without an
    # instance suffix (e.g. OmniFocus). It is embedded in idempotency keys,
    # so it can never change without breaking deduplication; the live
    # pipeline resolves identities through this same module so backfilled
    # and live rows share identities.
    DEFAULT_INSTANCE = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)

      {
        service_type:,
        service_instance: service_instance_for(service_type, item.source_service_instance),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end

    # `service_type` plus the configured instance name, falling back to the
    # default token when the service has none: "asana:work", "omnifocus:default".
    def service_instance_for(service_type, instance_name)
      [service_type, instance_name.presence || DEFAULT_INSTANCE].join(":")
    end
  end
end
