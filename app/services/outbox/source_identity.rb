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
      instance_name = item.source_service_instance.presence || "default"

      {
        service_type:,
        service_instance: [service_type, instance_name].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
