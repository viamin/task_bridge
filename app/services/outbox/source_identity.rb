# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)

      {
        service_type:,
        # The default segment is part of the permanent external identity. A
        # single-instance service must therefore not fall back to its bare
        # type: doing so would make its backfilled and live idempotency keys
        # disagree once an instance is later configured.
        service_instance: [service_type, item.source_service_instance.presence || "default"].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
