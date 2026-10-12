# frozen_string_literal: true

module SyncBackfill
  # Entry point for #222: generates baseline `item` snapshot rows and
  # `mapping` membership rows for existing TaskBridge data so TaskBridge Web
  # can seed current state before enabling publication. Run
  # SyncBackfill::SourceProvenance first — it establishes the identity and
  # mapping provenance this backfill depends on.
  module BaselineObservations
    module_function

    def run!(dry_run: false)
      {
        items: ItemSnapshots.run!(dry_run:),
        mappings: MappingObservations.run!(dry_run:)
      }
    end
  end
end
