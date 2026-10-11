# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by item, observation, and
  # mapping rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be
  # parsed by splitting on `:` because segments may themselves contain
  # colons.
  module SourceIdentity
    # Permanent default instance segment for single-instance services
    # (#222): OmniFocus, Reminders, and friends carry no instance suffix,
    # so without a token their identity would collapse to the bare
    # service type. The token is embedded in idempotency keys and item
    # identities, so it can never change without breaking every published
    # row — the live pipeline (#219-#221) resolves identities through this
    # same method so backfilled and live rows share one identity space.
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
