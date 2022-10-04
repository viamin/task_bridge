module TaskBridge
  class SyncItem
    attr_reader :source

    def initialize(item, options = {}, source = nil)
      @source = source
    end
  end
end
