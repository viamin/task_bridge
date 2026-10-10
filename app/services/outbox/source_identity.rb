# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by item, observation, and
  # mapping rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be
  # parsed by splitting on `:` because segments may themselves contain
  # colons.
  module SourceIdentity
    # Permanent instance segment for single-instance services (#222):
    # OmniFocus, Reminders, and other services without a configured
    # instance suffix have no source_service_instance, but the contract
    # requires a stable, non-empty service_instance on every row and it
    # is embedded in idempotency keys, so it can never change for the
    # life of the deployment.
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
