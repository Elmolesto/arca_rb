require "bigdecimal"

module Arca
  # Derives the fiscal amounts from the items so what ARCA authorizes and what
  # the PDF prints come from the same numbers.
  #
  # Items are priced as the caller sells them: VAT included by default. A
  # receipts print net prices, B and C print final prices; whichever side is
  # converted, the last item absorbs the rounding so the rows add up exactly.
  module Pricing
    Result = Data.define(:net_amount, :vat_amount, :items)

    module_function

    def call(receipt_type:, items:, vat_rate:, prices_include_vat:)
      items = Array(items).map { |item| item.is_a?(Pdf::Item) ? item : Pdf::Item.new(**Serialization.symbolize(item)) }
      raise InvalidRequest, "Un comprobante debe tener al menos un ítem" if items.empty?

      total = items.sum(BigDecimal("0"), &:subtotal)
      return Result.new(net_amount: total, vat_amount: BigDecimal("0"), items:) unless receipt_type.vat_charged

      rate = VatRate.fetch(vat_rate)
      if prices_include_vat
        amounts = VatRate.split(total:, percent: rate)
        net, vat = amounts.values_at(:net_amount, :vat_amount)
        printed = receipt_type.vat_discriminated ? convert(items, factor: 100 / (100 + rate), target: net, vat_rate: rate) : items
      else
        net = total
        vat = (net * rate / 100).round(2, BigDecimal::ROUND_HALF_UP)
        printed = receipt_type.vat_discriminated ? items.map { |item| item.with(vat_rate: rate) } : convert(items, factor: (100 + rate) / 100, target: net + vat)
      end

      Result.new(net_amount: net, vat_amount: vat, items: printed)
    end

    def convert(items, factor:, target:, vat_rate: nil)
      converted = items.map do |item|
        Pdf::Item.new(
          description: item.description, quantity: item.quantity, unit: item.unit, code: item.code,
          unit_price: (item.unit_price * factor).round(2, BigDecimal::ROUND_HALF_UP),
          discount_percent: item.discount_percent,
          discount_amount: (item.discount_amount * factor).round(2, BigDecimal::ROUND_HALF_UP),
          vat_rate:
        )
      end
      rounding = target - converted.sum(BigDecimal("0"), &:subtotal)
      converted[-1] = converted[-1].with(subtotal: converted[-1].subtotal + rounding) unless rounding.zero?
      converted
    end
  end
end
