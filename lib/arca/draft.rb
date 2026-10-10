module Arca
  # A receipt with its number reserved but not yet authorized. It snapshots
  # everything the receipt prints (issuer, point of sale, receiver, items) so
  # the app can persist it with `to_h` before calling ARCA and rebuild it with
  # `from_h` to retry or reprint.
  class Draft
    attr_reader :request, :issuer, :point_of_sale, :receiver, :items, :payment_condition, :observations

    def self.from_h(hash)
      data = Serialization.symbolize(hash)
      receiver = Pdf::Receiver.new(**Serialization.symbolize(data.fetch(:receiver)))

      new(
        request: Request.new(
          receipt_type: data.fetch(:receipt_type),
          receipt_number: data.fetch(:receipt_number),
          receiver: request_receiver(receiver),
          net_amount: data.fetch(:net_amount),
          vat_amount: data.fetch(:vat_amount),
          vat_rate: data.fetch(:vat_rate),
          issue_date: data.fetch(:issue_date),
          associated_receipts: Array(data[:associated_receipts]).map { |receipt| Serialization.symbolize(receipt) },
          concept: data.fetch(:concept, :products),
          service_period: data[:service_period]
        ),
        issuer: Issuer.new(**Serialization.symbolize(data.fetch(:issuer))),
        point_of_sale: PointOfSale.new(**Serialization.symbolize(data.fetch(:point_of_sale))),
        receiver:,
        items: data.fetch(:items).map { |item| Pdf::Item.new(**Serialization.symbolize(item)) },
        payment_condition: data[:payment_condition],
        observations: data[:observations]
      )
    end

    def self.request_receiver(receiver)
      Request::Receiver.new(document_type: receiver.document_type, document_number: receiver.document_number, vat_condition: receiver.vat_condition)
    end

    def initialize(request:, issuer:, point_of_sale:, receiver:, items:, payment_condition: "Contado", observations: nil)
      @request = request
      @issuer = issuer
      @point_of_sale = point_of_sale
      @receiver = receiver
      @items = items.freeze
      @payment_condition = payment_condition || "Contado"
      @observations = observations
    end

    def receipt_type = request.receipt_type
    def receipt_number = request.receipt_number
    def issue_date = request.issue_date
    def total_amount = request.total_amount
    def service_period = request.service_period

    # Without an authorization the document renders as a draft with no fiscal
    # validity.
    def document(authorization = nil)
      Pdf::Document.new(
        receipt_type:,
        point_of_sale: point_of_sale.number,
        receipt_number:,
        issued_on: issue_date,
        issuer:,
        commercial_address: point_of_sale.commercial_address,
        receiver:,
        items:,
        net_amount: request.net_amount,
        vat_amount: request.vat_amount,
        vat_lines: receipt_type.vat_charged && !request.vat_amount.zero? ? [ { rate: request.vat_rate, base: request.net_amount, amount: request.vat_amount } ] : [],
        service_period:,
        payment_condition:,
        associated_receipts: request.associated_receipts,
        observations:,
        cae: authorization&.cae,
        cae_expires_on: authorization&.expires_on
      )
    end

    def pdf(**options) = Pdf.render(document, **options)

    def to_h
      Serialization.dump(
        receipt_type: receipt_type.code,
        receipt_number:,
        issue_date:,
        vat_rate: request.vat_rate,
        net_amount: request.net_amount,
        vat_amount: request.vat_amount,
        concept: request.concept,
        issuer:,
        point_of_sale:,
        receiver:,
        items:,
        associated_receipts: request.associated_receipts,
        payment_condition:,
        service_period:,
        observations:
      )
    end
  end
end
