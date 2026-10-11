# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by item, observation, and
  # mapping rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be
  # parsed by splitting on `:` because segments may themselves contain
  # colons.
  module SourceIdentity
    # Permanent default instance segment (clarified decision on #222):
    # services configured without an instance suffix (OmniFocus,
    # Reminders, ...) publish "<service_type>:default" rather than a
    # bare service type. The token is embedded in idempotency keys, so
    # it can never change for a deployment once backfill or live
    # emission has used it. Services WITH an instance suffix keep
    # "<service_type>:<instance>".
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
