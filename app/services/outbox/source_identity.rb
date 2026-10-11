# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Single-instance services (OmniFocus, Reminders, ...) carry no instance
    # suffix, so their items have a blank source_service_instance. The
    # contract still requires a stable, non-empty service_instance on every
    # row, and it is embedded in idempotency keys, so the fallback token is
    # permanent once published (#222): it cannot change without breaking
    # every identity TaskBridge Web already holds.
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
