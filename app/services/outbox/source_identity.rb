# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Permanent fallback instance segment for services configured without
    # an instance suffix (e.g. OmniFocus): their publication identity is
    # "<service_type>:default" (clarified under #222, matching RDR #215's
    # `omnifocus:default` example). The token is embedded in idempotency
    # keys, so it can never change without breaking record identity; the
    # backfill and the live emitters share it through this module.
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
