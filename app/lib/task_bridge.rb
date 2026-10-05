# frozen_string_literal: true

# Deployment-level TaskBridge secrets that belong to the deployment rather
# than to a sync run's per-thread options (see GlobalOptions).
module TaskBridge
  module_function

  # HMAC-SHA256 key for the `notes_digest` published in normalized
  # snapshots (#219). Notes are sensitive by default (RDR #215), so the
  # digest is keyed instead of a bare SHA-256: consumers only ever compare
  # digests for equality within one deployment, and a keyed digest cannot
  # be matched against offline guesses of short note text. An explicit
  # `task_bridge.digest_key` setting (config/settings.yml) wins so the key
  # can be pinned or rotated; otherwise the deployment's secret_key_base
  # (a stable per-machine random secret) keys it out of the box. Rotating
  # the key only invalidates digest comparisons against the local
  # baseline: each item emits at most one spurious notes_digest transition
  # and sync semantics never change.
  def digest_key
    configured = Chamber.dig(:task_bridge, :digest_key).to_s
    return configured if configured.present?

    Rails.application.secret_key_base
  end
end
