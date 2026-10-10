# frozen_string_literal: true

module Outbox
  # Builds the RDR 215 source identity shared by observation, mapping, and
  # backfilled item snapshot rows so every record kind agrees on how a
  # Base::SyncItem is identified. The values are opaque to consumers: they
  # must not be parsed by splitting on `:` because segments may themselves
  # contain colons.
  module SourceIdentity
    # Terminal segment of every service_instance, matching the RDR #215
    # example `asana:workspace-12345:default`: single-instance services
    # resolve to `<service_type>:default` (e.g. `omnifocus:default`) and
    # configured instances to `<service_type>:<instance>:default`. This
    # default is permanent: it is embedded in idempotency keys, so changing
    # it would fork the identity of every published row (#222).
    DEFAULT_INSTANCE_TOKEN = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)

      {
        service_type:,
        service_instance: [service_type, item.source_service_instance, DEFAULT_INSTANCE_TOKEN].compact.join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
