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
        service_instance: [service_type, item.source_service_instance].compact.join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end

    # Service-level identity for records that are not tied to one item, such
    # as sync-run summaries: the adapter-family identifier plus the
    # configured instance, matching the item-level shape above so rows from
    # the same service correlate downstream.
    def for_service_name(service_name)
      class_identifier = Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))

      {
        service_type: class_identifier,
        service_instance: [class_identifier, Base::Service.instance_name_for(service_name)].compact.join(":")
      }
    end
  end
end
