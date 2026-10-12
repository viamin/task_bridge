# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Default token used for services without a configured instance suffix
    # (RDR #215 Identity Model). The contract requires `service_instance`
    # on every item and observation row, and the value is embedded in
    # idempotency keys, so a single-instance service like OmniFocus,
    # Reminders, or un-prefixed Asana gets a stable `<service_type>:default`
    # identity (#222). The default is permanent: switching it later would
    # change idempotency keys and replay every stored row.
    DEFAULT_INSTANCE_TOKEN = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)

      {
        service_type:,
        service_instance: instance_for(service_type, item.source_service_instance),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end

    def instance_for(service_type, instance_name)
      segment = instance_name.presence || DEFAULT_INSTANCE_TOKEN

      "#{service_type}:#{segment}"
    end
  end
end
