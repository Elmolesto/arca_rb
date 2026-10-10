require "bigdecimal"
require "date"

module Arca
  # A receipt ready to be authorized. Validates every fiscal rule that can be
  # checked locally, so a broken request never reaches ARCA.
  class Request
    Receiver = Data.define(:document_type, :document_number, :vat_condition) do
      def initialize(document_type:, document_number:, vat_condition:)
        identity = Identity.normalize(document_type:, document_number:)
        super(document_type: identity.fetch(:type), document_number: identity.fetch(:number), vat_condition: VatCondition.fetch(vat_condition))
      end

      def self.unidentified_final_consumer = new(document_type: :unidentified, document_number: 0, vat_condition: :final_consumer)

      def document_type_code = Identity.code_for(document_type)
      def vat_condition_id = VatCondition.id_for(vat_condition)
      def valid? = Identity.valid?(document_type:, document_number:)
    end

    AssociatedReceipt = Data.define(:receipt_type, :point_of_sale, :receipt_number) do
      def initialize(receipt_type:, point_of_sale:, receipt_number:)
        definition = ReceiptType.fetch(receipt_type)
        raise InvalidRequest, "El comprobante asociado debe ser una factura o una nota de débito" if definition.credit_note?
        raise InvalidRequest, "El punto de venta asociado debe ser positivo" unless Integer(point_of_sale).positive?
        raise InvalidRequest, "El número asociado debe ser positivo" unless Integer(receipt_number).positive?

        super(receipt_type: definition.code, point_of_sale: Integer(point_of_sale), receipt_number: Integer(receipt_number))
      rescue TypeError, ArgumentError => error
        raise error if error.is_a?(InvalidRequest)

        raise InvalidRequest, "El comprobante asociado no es válido"
      end
    end

    # WSFE Concepto. Services (2 and 3) must report the billed period.
    CONCEPTS = { products: 1, services: 2, products_and_services: 3 }.freeze

    attr_reader :receipt_type, :receipt_number, :receiver, :net_amount, :vat_amount, :vat_rate, :issue_date, :associated_receipts, :concept, :service_period

    # A `service_period` on a products receipt is only printed, never sent.
    def initialize(receipt_type:, receipt_number:, receiver:, net_amount:, vat_amount:, issue_date:, vat_rate: VatRate::DEFAULT, associated_receipts: [],
      concept: :products, service_period: nil)
      @receipt_type = ReceiptType.fetch(receipt_type)
      @receipt_number = integer!(receipt_number, "El número de comprobante no es válido")
      @receiver = receiver.is_a?(Receiver) ? receiver : Receiver.new(**receiver)
      @net_amount = decimal!(net_amount)
      @vat_amount = decimal!(vat_amount)
      @vat_rate = VatRate.fetch(vat_rate)
      @issue_date = date!(issue_date)
      @associated_receipts = Array(associated_receipts).map { |receipt| receipt.is_a?(AssociatedReceipt) ? receipt : AssociatedReceipt.new(**receipt) }.freeze
      @concept = concept.to_s.to_sym
      @service_period = ServicePeriod.wrap(service_period)

      validate!
    end

    def total_amount = net_amount + vat_amount

    def invoice? = receipt_type.invoice?
    def credit_note? = receipt_type.credit_note?
    def debit_note? = receipt_type.debit_note?
    def vat_discriminated? = receipt_type.vat_discriminated && !vat_amount.zero?
    def concept_code = CONCEPTS.fetch(concept)
    def services? = concept != :products

    private

    def validate!
      raise InvalidRequest, "El número de comprobante debe ser positivo" unless receipt_number.positive?
      raise InvalidRequest, "El documento fiscal del receptor no es válido" unless receiver.valid?
      unless receipt_type.accepts_receiver?(receiver.vat_condition)
        raise InvalidRequest, "La condición frente al IVA del receptor no permite emitir una #{receipt_type.document_title.capitalize} #{receipt_type.letter}"
      end
      raise InvalidRequest, "El importe neto no puede ser negativo" if net_amount.negative?
      raise InvalidRequest, "El IVA no puede ser negativo" if vat_amount.negative?
      raise InvalidRequest, "Los comprobantes #{receipt_type.letter} no discriminan IVA" if !receipt_type.vat_charged && !vat_amount.zero?

      validate_concept!
      validate_associated_receipts!
    end

    def validate_concept!
      raise InvalidRequest, "El concepto del comprobante no es válido" unless CONCEPTS.key?(concept)
      return unless services?

      raise InvalidRequest, "Los comprobantes de servicios necesitan el período facturado y el vencimiento del pago" unless service_period
      raise InvalidRequest, "El vencimiento del pago no puede ser anterior a la fecha del comprobante" if service_period.payment_due < issue_date
    end

    # Credit and debit notes must reference what they adjust, with its letter.
    def validate_associated_receipts!
      raise InvalidRequest, "Las facturas no pueden tener comprobantes asociados" if invoice? && associated_receipts.any?
      return if invoice?

      raise InvalidRequest, "La #{receipt_type.document_title.downcase} debe referenciar el comprobante que ajusta" if associated_receipts.empty?
      unless associated_receipts.all? { |receipt| ReceiptType.fetch(receipt.receipt_type).letter == receipt_type.letter }
        raise InvalidRequest, "La #{receipt_type.document_title.downcase} debe tener la misma letra que el comprobante asociado"
      end
    end

    def integer!(value, message)
      Integer(value)
    rescue ArgumentError, TypeError
      raise InvalidRequest, message
    end

    def decimal!(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      raise InvalidRequest, "Los importes del comprobante no son válidos"
    end

    def date!(value)
      return value if value.instance_of?(Date)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError, TypeError
      raise InvalidRequest, "La fecha del comprobante no es válida"
    end
  end
end
