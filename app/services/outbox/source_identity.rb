# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # v1 default instance token for services configured without an instance
    # suffix (e.g. `Omnifocus` rather than `Asana:work`), yielding
    # `omnifocus:default` (#222 clarified decision, matching the RDR #215
    # example `asana:workspace-12345:default`). The token is permanent: it
    # is embedded in idempotency keys, so the live pipeline (#219-#221) and
    # the baseline backfill (#222) must resolve it here — the one shared
    # identity chokepoint — so their rows key identically.
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
