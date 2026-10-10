require "bigdecimal"
require "date"

module Arca
  # Turns value objects into JSON-safe hashes with string keys, so drafts and
  # issued receipts can be stored in a jsonb column and rebuilt later.
  module Serialization
    module_function

    def dump(value)
      case value
      when Hash then value.to_h { |key, entry| [ key.to_s, dump(entry) ] }
      when Array then value.map { |entry| dump(entry) }
      when Data then dump(value.to_h)
      when BigDecimal then value.to_s("F")
      when Date then value.iso8601
      when Symbol then value.to_s
      else value
      end
    end

    def symbolize(hash) = hash.to_h.transform_keys(&:to_sym)
  end
end
