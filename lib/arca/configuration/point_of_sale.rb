module Arca
  # A point of sale enabled in ARCA for web service invoicing. Each one is
  # registered against an address, usually a branch, but ARCA's web services
  # never return it, so the commercial address printed on receipts is set here.
  PointOfSale = Data.define(:number, :commercial_address, :name) do
    def initialize(number:, commercial_address: nil, name: nil)
      number = Integer(number)
      raise ArgumentError unless number.positive?

      super(number:, commercial_address:, name:)
    rescue ArgumentError, TypeError
      raise ArgumentError, "El punto de venta debe ser un número positivo"
    end
  end
end
