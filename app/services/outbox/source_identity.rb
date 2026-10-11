# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Services without a configured instance (OmniFocus, Reminders, ...) have
    # no suffix in `source_service_instance`. `service_instance` is embedded
    # in every idempotency key (#222), so it must be stable forever once a
    # deployment starts publishing; backfill and the live pipeline share this
    # default rather than each inventing their own.
    DEFAULT_INSTANCE_TOKEN = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)

      {
        service_type:,
        service_instance: [service_type, item.source_service_instance.presence || DEFAULT_INSTANCE_TOKEN].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
