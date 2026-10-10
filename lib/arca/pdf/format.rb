require "bigdecimal"
require "date"

module Arca
  module Pdf
    # Argentine formatting for amounts, dates and numbers in words.
    module Format
      module_function

      def money(amount, symbol: "$")
        whole, decimals = format("%.2f", BigDecimal(amount.to_s).round(2)).split(".")
        sign = whole.start_with?("-") ? "-" : ""
        "#{sign}#{symbol} #{whole.delete("-").reverse.scan(/\d{1,3}/).join(".").reverse},#{decimals}"
      end

      def number(value, decimals: 2) = format("%.#{decimals}f", BigDecimal(value.to_s)).tr(".", ",")

      def percentage(value) = "#{BigDecimal(value.to_s).round(2).to_s("F").delete_suffix(".0").tr(".", ",")}%"

      def date(value) = value.nil? ? "" : value.strftime("%d/%m/%Y")
      def point_of_sale(value) = value.to_s.rjust(5, "0")
      def receipt_number(value) = value.to_s.rjust(8, "0")
      def cuit(value) = value.to_s.gsub(/\D/, "").then { |digits| digits.length == 11 ? "#{digits[0, 2]}-#{digits[2, 8]}-#{digits[10]}" : digits }

      def amount_in_words(amount)
        cents = (BigDecimal(amount.to_s) * 100).round.to_i
        "#{words(cents / 100).upcase} CON #{(cents % 100).to_s.rjust(2, "0")}/100"
      end

      def words(number)
        return "cero" if number.zero?

        parts = []
        millions, number = number.divmod(1_000_000)
        parts << (millions == 1 ? "un millón" : "#{apocopate(words(millions))} millones") if millions.positive?
        thousands, number = number.divmod(1_000)
        parts << (thousands == 1 ? "mil" : "#{apocopate(under_one_thousand(thousands))} mil") if thousands.positive?
        parts << under_one_thousand(number) if number.positive?
        parts.join(" ")
      end

      # "veintiuno mil" is "veintiún mil"; "ciento uno mil" is "ciento un mil".
      def apocopate(words) = words.sub(/veintiuno\z/, "veintiún").sub(/(\A|\s)uno\z/, '\1un')

      def under_one_thousand(number)
        hundreds, remainder = number.divmod(100)
        prefix = [ nil, "cien", "doscientos", "trescientos", "cuatrocientos", "quinientos", "seiscientos", "setecientos", "ochocientos", "novecientos" ][hundreds]
        prefix = "ciento" if hundreds == 1 && remainder.positive?
        [ prefix, remainder.zero? ? nil : under_one_hundred(remainder) ].compact.join(" ")
      end

      def under_one_hundred(number)
        units = %w[cero uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince]
        return units[number] if number <= 15
        return "dieci#{units[number - 10]}".sub("dieciseis", "dieciséis") if number < 20
        return "veinte" if number == 20
        return "veinti#{units[number - 20]}".sub("veintidos", "veintidós").sub("veintitres", "veintitrés").sub("veintiseis", "veintiséis") if number < 30

        tens, unit = number.divmod(10)
        tens_word = [ nil, nil, nil, "treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa" ].fetch(tens)
        unit.zero? ? tens_word : "#{tens_word} y #{units[unit]}"
      end
    end
  end
end
