# frozen_string_literal: true

module Outbox
  # Builds the RDR 215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Permanent default instance segment for single-instance services
    # (OmniFocus, Reminders, …) whose service name carries no instance
    # suffix, so `service_instance` is always present (#222). The token is
    # embedded in idempotency keys, so it can never change for the life of
    # the deployment: `omnifocus` publishes as `omnifocus:default` forever.
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
