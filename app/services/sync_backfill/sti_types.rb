# frozen_string_literal: true

module SyncBackfill
  # Iterates persisted sync items grouped by STI type. A plain
  # `Base::SyncItem.find_each` materializes whole batches at once, so a
  # single row whose `type` no longer resolves to a Base::SyncItem
  # subclass (a renamed or removed adapter) raises SubclassNotFound and
  # aborts the entire run; grouping by type lets backfills count or skip
  # those rows instead (#222). Typeless rows are skipped here too:
  # instantiating Base::SyncItem itself raises inside read_notes because
  # #provider is not implemented on the base class.
  module StiTypes
    module_function

    def each_item(&)
      Base::SyncItem.distinct.pluck(:type).each do |type|
        next if type.nil?

        klass = resolvable_class(type)
        next if klass.nil?

        Base::SyncItem.where(type: type).find_each(&)
      end
    end

    # The STI class a persisted `type` value resolves to, or nil when the
    # value is missing, unloadable, or not a strict Base::SyncItem
    # subclass.
    def resolvable_class(type)
      return if type.nil?

      klass = type.safe_constantize
      klass if klass.is_a?(Class) && klass < Base::SyncItem
    end
  end
end
