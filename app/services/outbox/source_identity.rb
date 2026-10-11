# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 source identity shared by observation and mapping
  # rows so both record kinds agree on how a Base::SyncItem is identified.
  # The values are opaque to consumers: they must not be parsed by splitting
  # on `:` because segments may themselves contain colons.
  module SourceIdentity
    # Services with no configured instance suffix (OmniFocus, Reminders, a
    # single-workspace Asana, ...) still need a stable `service_instance`
    # segment because it is embedded permanently in idempotency keys
    # (RDR #215 "Idempotency Keys"; #222 backfill clarification). This
    # token cannot change later without invalidating every key already
    # published, so both the live pipeline and the backfill (#222) derive
    # it from this single shared method.
    DEFAULT_INSTANCE_TOKEN = "default"

    module_function

    def for(item)
      service_type = Base::Service.service_identifier_for(item.provider)
      instance_token = item.source_service_instance.presence || DEFAULT_INSTANCE_TOKEN

      {
        service_type:,
        service_instance: [service_type, instance_token].join(":"),
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end
  end
end
