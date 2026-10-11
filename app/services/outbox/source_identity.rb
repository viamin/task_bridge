# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Permanent default instance segment for single-instance services
    # (#222): services without a configured instance suffix — OmniFocus,
    # Reminders, Google Tasks — have no source_service_instance, but the
    # contract requires a stable service_instance and it is embedded in
    # idempotency keys, so it can never change once published. Live
    # emitters and the baseline backfill share this token so backfilled
    # and live rows claim the same identity.
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
