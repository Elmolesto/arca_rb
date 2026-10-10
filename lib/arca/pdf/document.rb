require "bigdecimal"
require "date"

module Arca
  module Pdf
    Receiver = Data.define(:legal_name, :document_type, :document_number, :vat_condition, :fiscal_address) do
      def initialize(document_type:, document_number:, vat_condition:, legal_name: nil, fiscal_address: nil)
        identity = Identity.normalize(document_type:, document_number:)
        super(legal_name:, document_type: identity.fetch(:type), document_number: identity.fetch(:number), vat_condition:, fiscal_address:)
      end

      def document_type_code = Identity.code_for(document_type)
      def unidentified? = document_type == :unidentified
      def final_consumer? = VatCondition.valid?(vat_condition) && VatCondition.fetch(vat_condition) == :final_consumer
    end

    # `unit_price` is what the row shows: net of VAT on A receipts, VAT
    # included on B and C. `subtotal` defaults to quantity × price − discount.
    Item = Data.define(:description, :quantity, :unit_price, :unit, :code, :discount_percent, :discount_amount, :vat_rate, :subtotal) do
      def initialize(description:, unit_price:, quantity: 1, unit: "unidades", code: nil, discount_percent: 0, discount_amount: nil, vat_rate: nil, subtotal: nil)
        quantity = BigDecimal(quantity.to_s)
        unit_price = BigDecimal(unit_price.to_s)
        discount_percent = BigDecimal(discount_percent.to_s)
        gross = quantity * unit_price
        discount_amount = discount_amount.nil? ? (gross * discount_percent / 100).round(2) : BigDecimal(discount_amount.to_s)
        subtotal = subtotal.nil? ? gross - discount_amount : BigDecimal(subtotal.to_s)

        super(description: description.to_s, quantity:, unit_price:, unit:, code:, discount_percent:, discount_amount:, vat_rate: vat_rate && VatRate.fetch(vat_rate), subtotal:)
      end
    end

    VatLine = Data.define(:rate, :base, :amount) do
      def initialize(rate:, base:, amount:)
        super(rate: VatRate.fetch(rate), base: BigDecimal(base.to_s), amount: BigDecimal(amount.to_s))
      end
    end

    # Everything a receipt prints. Without a CAE it renders as a draft with no
    # fiscal validity: no QR, no CAE and a banner saying so.
    class Document
      CURRENCIES = { "PES" => { symbol: "$", name: "PESOS ARGENTINOS (ARS)" }, "DOL" => { symbol: "US$", name: "DÓLARES ESTADOUNIDENSES (USD)" } }.freeze

      attr_reader :receipt_type, :point_of_sale, :receipt_number, :issued_on, :issuer, :commercial_address, :receiver, :items,
        :net_amount, :vat_amount, :exempt_amount, :untaxed_amount, :other_taxes_amount, :total_amount, :vat_lines,
        :service_period, :payment_condition, :associated_receipts, :observations, :currency, :exchange_rate, :cae, :cae_expires_on

      # `commercial_address` is the branch address printed as "Domicilio
      # Comercial"; it defaults to the issuer's fiscal address.
      def initialize(receipt_type:, issued_on:, issuer:, receiver:, items:, net_amount:, point_of_sale: nil, receipt_number: nil, commercial_address: nil,
        vat_amount: 0, exempt_amount: 0, untaxed_amount: 0, other_taxes_amount: 0, total_amount: nil, vat_lines: nil,
        service_period: nil, payment_condition: "Contado", associated_receipts: [], observations: nil,
        currency: "PES", exchange_rate: 1, cae: nil, cae_expires_on: nil)
        @receipt_type = ReceiptType.fetch(receipt_type)
        @point_of_sale = point_of_sale && Integer(point_of_sale)
        @receipt_number = receipt_number && Integer(receipt_number)
        @issued_on = date(issued_on)
        @issuer = issuer.is_a?(Arca::Issuer) ? issuer : Arca::Issuer.new(**issuer)
        @commercial_address = commercial_address || @issuer.fiscal_address
        @receiver = receiver.is_a?(Receiver) ? receiver : Receiver.new(**receiver)
        @items = items.map { |item| item.is_a?(Item) ? item : Item.new(**item) }.freeze
        @net_amount = BigDecimal(net_amount.to_s)
        @vat_amount = BigDecimal(vat_amount.to_s)
        @exempt_amount = BigDecimal(exempt_amount.to_s)
        @untaxed_amount = BigDecimal(untaxed_amount.to_s)
        @other_taxes_amount = BigDecimal(other_taxes_amount.to_s)
        @total_amount = total_amount.nil? ? @net_amount + @vat_amount + @exempt_amount + @untaxed_amount + @other_taxes_amount : BigDecimal(total_amount.to_s)
        @vat_lines = (vat_lines || default_vat_lines).map { |line| line.is_a?(VatLine) ? line : VatLine.new(**line.to_h) }.freeze
        @service_period = Arca::ServicePeriod.wrap(service_period)
        @payment_condition = payment_condition
        @associated_receipts = associated_receipts.map { |receipt| receipt.is_a?(Request::AssociatedReceipt) ? receipt : Request::AssociatedReceipt.new(**receipt) }.freeze
        @observations = observations
        @currency = CURRENCIES.key?(currency) ? currency : raise(ArgumentError, "Moneda no soportada: #{currency}")
        @exchange_rate = BigDecimal(exchange_rate.to_s)
        @cae = cae&.to_s
        @cae_expires_on = cae_expires_on && date(cae_expires_on)

        validate!
      end

      def authorized? = !@cae.nil?
      def draft? = !authorized?
      def letter = receipt_type.letter
      def currency_symbol = CURRENCIES.fetch(currency).fetch(:symbol)
      def currency_name = CURRENCIES.fetch(currency).fetch(:name)

      def qr
        Qr.new(
          issued_on:, issuer_cuit: issuer.cuit, point_of_sale:, receipt_type: receipt_type.code, receipt_number:, total: total_amount, cae:,
          receiver_document_type: receiver.unidentified? ? nil : receiver.document_type,
          receiver_document_number: receiver.unidentified? ? nil : receiver.document_number,
          currency:, exchange_rate:
        )
      end

      private

      def validate!
        raise ArgumentError, "Un comprobante debe tener al menos un ítem" if items.empty?
        return if draft?

        raise ArgumentError, "Un comprobante autorizado necesita punto de venta y número" unless point_of_sale&.positive? && receipt_number&.positive?
        raise ArgumentError, "Un comprobante autorizado necesita la fecha de vencimiento del CAE" unless cae_expires_on
      end

      def default_vat_lines
        return [] unless receipt_type.vat_charged && !@vat_amount.zero?

        [ { rate: VatRate::DEFAULT, base: @net_amount, amount: @vat_amount } ]
      end

      def date(value)
        return value if value.instance_of?(Date)
        return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

        Date.iso8601(value.to_s)
      end
    end
  end
end
