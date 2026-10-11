# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    module_function

    def for(item)
      service_type = publication_service_type(item)

      {
        service_type:,
        # Single-instance adapters still need a permanent instance component:
        # it participates in both item identity and idempotency keys.
        service_instance: [service_type, item.source_service_instance.presence || "default"].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end

    def publication_service_type(item)
      Base::Service.service_identifier_for(item.provider).sub("omni_focus", "omnifocus")
    end
  end
end
