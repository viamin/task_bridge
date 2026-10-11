# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by item, observation, and
  # mapping rows so every record kind agrees on how a Base::SyncItem is
  # identified. The values are opaque to consumers: they must not be parsed
  # by splitting on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Permanent default for services without a configured instance suffix
    # (OmniFocus, Reminders, Google Tasks, ...). The token is embedded in
    # idempotency keys, so it can never change without breaking record
    # identity; the live pipeline and the baseline backfill (#222) resolve
    # it here so their rows share identities. Matches the RDR #215 example
    # "asana:workspace-12345:default".
    DEFAULT_INSTANCE_TOKEN = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)
      instance = item.source_service_instance.presence || DEFAULT_INSTANCE_TOKEN

      {
        service_type:,
        service_instance: [service_type, instance].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
