# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    SERVICE_TYPE_ALIASES = { "omni_focus" => "omnifocus" }.freeze

    module_function

    def for(item)
      service_type = SERVICE_TYPE_ALIASES.fetch(Base::Service.service_identifier_for(item.provider)) do |identifier|
        identifier
      end

      {
        service_type:,
        # A single configured source still needs a stable instance component:
        # it is part of the immutable publication idempotency key.  Do not use
        # an empty segment here; legacy rows have no instance suffix.
        service_instance: [service_type, item.source_service_instance.presence || "default"].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
