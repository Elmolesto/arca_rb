module Arca
  Error = Class.new(StandardError)

  # Local setup is wrong: unknown environment, missing or mismatched
  # certificate, invalid CUIT or point of sale. Retrying will not help.
  ConfigurationError = Class.new(Error)

  # ARCA could not be reached. Safe to retry later.
  TransientError = Class.new(Error)

  # The request breaks a fiscal rule and was never sent to ARCA. Inherits from
  # ArgumentError so callers that validate input generically keep working.
  InvalidRequest = Class.new(ArgumentError)

  # ARCA answered and refused the operation. `message` only carries the ARCA
  # codes so it can be shown or persisted; the provider's free text, which may
  # echo request data, stays in `diagnostics`.
  class Rejection < Error
    def initialize(message, codes: [], diagnostics: [])
      super(message)
      @codes = codes.freeze
      @diagnostics = diagnostics.freeze
    end

    attr_reader :codes, :diagnostics
  end

  # ARCA refused the reserved number because another receipt already uses it.
  # The draft must be prepared again to get a new number.
  ReceiptNumberTaken = Class.new(Rejection)
end
