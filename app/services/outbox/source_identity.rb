# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    CANONICAL_SERVICE_TYPES = {
      "git_hub" => "github",
      "omni_focus" => "omnifocus"
    }.freeze

    module_function

    def for(item)
      service_type = canonical_service_type(item.provider)

      {
        service_type:,
        service_instance: [service_type, item.source_service_instance].compact.join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end

    def for_backfill(item)
      identity = self.for(item)
      return identity unless identity.fetch(:service_instance) == identity.fetch(:service_type)

      identity.merge(service_instance: "#{identity.fetch(:service_type)}:default")
    end

    def canonical_service_type(provider)
      identifier = Base::Service.service_identifier_for(provider)
      CANONICAL_SERVICE_TYPES.fetch(identifier, identifier)
    end
  end
end
