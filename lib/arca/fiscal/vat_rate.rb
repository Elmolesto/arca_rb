require "bigdecimal"

module Arca
  # VAT rates accepted by WSFE (AlicIva Id), keyed by percentage.
  module VatRate
    IDS = {
      BigDecimal("0") => 3,
      BigDecimal("2.5") => 9,
      BigDecimal("5") => 8,
      BigDecimal("10.5") => 4,
      BigDecimal("21") => 5,
      BigDecimal("27") => 6
    }.freeze
    DEFAULT = BigDecimal("21")

    def self.fetch(percent)
      rate = BigDecimal(percent.to_s)
      return rate if IDS.key?(rate)

      raise InvalidRequest, "La alícuota de IVA no está soportada por ARCA"
    rescue ArgumentError, TypeError
      raise InvalidRequest, "La alícuota de IVA no está soportada por ARCA"
    end

    def self.id_for(percent) = IDS.fetch(fetch(percent))

    # Splits a VAT-inclusive total into net and VAT, rounded to cents. The VAT
    # is derived from the rounded net so both always add up to the total.
    def self.split(total:, percent: DEFAULT)
      total = BigDecimal(total.to_s)
      rate = fetch(percent)
      net = (total * 100 / (100 + rate)).round(2, BigDecimal::ROUND_HALF_UP)

      { net_amount: net, vat_amount: total - net }
    end
  end
end
