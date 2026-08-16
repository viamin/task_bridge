# frozen_string_literal: true

module Publication
  module HashAccess
    module_function

    def fetch(hash, key)
      return hash[key] if hash.key?(key)

      hash[key.to_s]
    end

    def key?(hash, key)
      hash.key?(key) || hash.key?(key.to_s)
    end
  end
end
