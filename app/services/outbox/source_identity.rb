# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by item, observation, and
  # mapping rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be parsed
  # by splitting on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Single-instance services (OmniFocus, Reminders, ...) have no configured
    # instance suffix, but the contract requires a service_instance and it is
    # embedded in idempotency keys, so it can never change once published
    # (#222): those services publish `<service_type>:default`, matching the
    # RDR's `asana:workspace-12345:default` example shape. Backfilled and
    # live rows therefore share identities.
    DEFAULT_INSTANCE = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)
      instance = item.source_service_instance.presence || DEFAULT_INSTANCE

      {
        service_type:,
        service_instance: "#{service_type}:#{instance}",
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
