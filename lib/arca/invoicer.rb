module Arca
  # Issues receipts for one issuer at one point of sale, in two steps so the
  # app can persist the reserved number before ARCA sees it:
  #
  #   draft = invoicer.prepare(receiver:, items:, issue_date:)
  #   record.update!(arca: draft.to_h)
  #   receipt = invoicer.authorize(draft)   # safe to retry with the same draft
  #
  # Retrying `authorize` after a crash never issues a second receipt: if ARCA
  # already holds that number for the same receiver and total, the existing
  # authorization is returned.
  class Invoicer
    # WSFE: the number or date is not the next one ARCA expects.
    OUT_OF_SEQUENCE = "10016"

    attr_reader :issuer, :point_of_sale, :client

    def initialize(credentials:, issuer:, point_of_sale:, transport: Soap::Transport.new, client: nil)
      @issuer = issuer.is_a?(Issuer) ? issuer : Issuer.new(**issuer)
      @point_of_sale = point_of_sale.is_a?(PointOfSale) ? point_of_sale : PointOfSale.new(**point_of_sale)
      @client = client || Client.new(credentials:, issuer_cuit: @issuer.cuit, point_of_sale: @point_of_sale.number, transport:)
    end

    # Picks the letter from the issuer and receiver VAT conditions, derives the
    # amounts from the items and reserves the next number in ARCA.
    #
    # A `service_period` makes it a services receipt (concept 2) unless
    # `concept:` says otherwise.
    def prepare(receiver:, items:, issue_date:, vat_rate: VatRate::DEFAULT, prices_include_vat: true, receipt_number: nil,
      payment_condition: "Contado", service_period: nil, concept: nil, observations: nil)
      receiver = printed_receiver(receiver)
      receipt_type = ReceiptType.for(issuer_vat_condition: issuer.vat_condition, receiver_vat_condition: receiver.vat_condition)
      pricing = Pricing.call(receipt_type:, items:, vat_rate:, prices_include_vat:)
      concept ||= service_period ? :services : :products

      build_draft(receipt_type:, receipt_number:, receiver:, pricing:, vat_rate:, issue_date:, payment_condition:, concept:, service_period:, observations:)
    end

    # A credit note for `receipt`, whole by default or for the given items.
    def prepare_credit_note(receipt, issue_date:, items: nil, prices_include_vat: true, receipt_number: nil, observations: nil)
      original = receipt.draft
      receipt_type = ReceiptType.credit_note_for(original.receipt_type)
      vat_rate = original.request.vat_rate
      pricing = if items
        Pricing.call(receipt_type:, items:, vat_rate:, prices_include_vat:)
      else
        Pricing::Result.new(net_amount: original.request.net_amount, vat_amount: original.request.vat_amount, items: original.items)
      end
      if pricing.net_amount + pricing.vat_amount > receipt.total_amount
        raise InvalidRequest, "La nota de crédito no puede superar el total de la factura"
      end

      build_draft(
        receipt_type:, receipt_number:, receiver: original.receiver, pricing:, vat_rate:, issue_date:,
        payment_condition: original.payment_condition, concept: original.request.concept,
        service_period: credit_note_period(original.service_period, issue_date), observations:,
        associated_receipts: [ { receipt_type: original.receipt_type.code, point_of_sale: receipt.point_of_sale.number, receipt_number: receipt.number } ]
      )
    end

    # A debit note charging `items` on top of `receipt` (late fees, price
    # adjustments). Same letter, receiver and concept as the invoice.
    def prepare_debit_note(receipt, issue_date:, items:, prices_include_vat: true, receipt_number: nil, observations: nil)
      original = receipt.draft
      receipt_type = ReceiptType.debit_note_for(original.receipt_type)
      vat_rate = original.request.vat_rate

      build_draft(
        receipt_type:, receipt_number:, receiver: original.receiver, pricing: Pricing.call(receipt_type:, items:, vat_rate:, prices_include_vat:),
        vat_rate:, issue_date:, payment_condition: original.payment_condition, concept: original.request.concept,
        service_period: credit_note_period(original.service_period, issue_date), observations:,
        associated_receipts: [ { receipt_type: original.receipt_type.code, point_of_sale: receipt.point_of_sale.number, receipt_number: receipt.number } ]
      )
    end

    def verify_point_of_sale! = client.verify_point_of_sale!

    def authorize(draft)
      unless draft.point_of_sale.number == point_of_sale.number && draft.issuer.cuit == issuer.cuit
        raise ArgumentError, "El borrador pertenece a otro emisor o punto de venta"
      end

      IssuedReceipt.new(draft:, authorization: client.authorize(request: draft.request))
    rescue Rejection => error
      raise unless error.codes.include?(OUT_OF_SEQUENCE)

      recover(draft, error)
    end

    private

    # A note bills the same period as its invoice, but its payment cannot fall
    # due before the note itself.
    def credit_note_period(period, issue_date)
      return unless period

      issued_on = issue_date.is_a?(Date) ? issue_date : Date.iso8601(issue_date.to_s)
      period.with(payment_due: [ period.payment_due, issued_on ].max)
    end

    def build_draft(receipt_type:, receipt_number:, receiver:, pricing:, vat_rate:, issue_date:, payment_condition:, concept:, service_period:, observations:, associated_receipts: [])
      request = Request.new(
        receipt_type:,
        receipt_number: receipt_number || client.next_receipt_number(receipt_type:),
        receiver: Draft.request_receiver(receiver),
        net_amount: pricing.net_amount,
        vat_amount: pricing.vat_amount,
        vat_rate:,
        issue_date:,
        associated_receipts:,
        concept:,
        service_period:
      )

      Draft.new(request:, issuer:, point_of_sale:, receiver:, items: pricing.items, payment_condition:, observations:)
    end

    def printed_receiver(receiver)
      receiver = receiver.is_a?(Pdf::Receiver) ? receiver : Pdf::Receiver.new(**Serialization.symbolize(receiver))
      receiver.with(vat_condition: VatCondition.fetch(receiver.vat_condition))
    end

    # ARCA refused the number. If it already holds this very receipt (a retry
    # after a lost response), return it; if another receipt took the number,
    # the draft must be prepared again. Anything else is a date problem and
    # the original rejection stands.
    def recover(draft, error)
      existing = client.consult_receipt(receipt_type: draft.receipt_type, receipt_number: draft.receipt_number)
      raise error unless existing

      if existing.total == draft.total_amount && existing.receiver_document_number == draft.request.receiver.document_number
        authorization = Client::Authorization.new(number: existing.number, cae: existing.cae, expires_on: existing.expires_on)
        return IssuedReceipt.new(draft:, authorization:, recovered: true)
      end

      raise ReceiptNumberTaken.new(
        "El número #{draft.receipt_number} ya fue usado por otro comprobante; hay que preparar el comprobante de nuevo",
        codes: error.codes, diagnostics: error.diagnostics
      )
    end
  end
end
