# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Services configured without an instance suffix (OmniFocus, Reminders,
    # ...) carry no source_service_instance, but the publication contract
    # requires a stable service_instance that is embedded in idempotency
    # keys (#222). The fixed `default` token is permanent — it cannot change
    # later without breaking already-published keys — and the live pipeline
    # resolves it here too so backfilled and live rows share identities.
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
