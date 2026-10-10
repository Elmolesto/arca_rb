require "date"

module Arca
  # The period a services receipt bills and when it is due. Required by WSFE
  # for concepts 2 and 3 (FchServDesde, FchServHasta, FchVtoPago).
  ServicePeriod = Data.define(:from, :to, :payment_due) do
    def initialize(from:, to:, payment_due:)
      from, to, payment_due = [ from, to, payment_due ].map { |value| parse(value) }
      raise InvalidRequest, "El período facturado termina antes de empezar" if to < from

      super(from:, to:, payment_due:)
    end

    def self.wrap(value) = value.nil? || value.is_a?(self) ? value : new(**Serialization.symbolize(value))

    private

    def parse(value)
      return value if value.instance_of?(Date)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError, TypeError
      raise InvalidRequest, "Las fechas del período facturado no son válidas"
    end
  end
end
