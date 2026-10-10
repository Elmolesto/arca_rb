require "test_helper"
require "json"
require "pdf-reader"

class Arca::InvoicerTest < Minitest::Test
  # Behaves like WSFE for one point of sale: each receipt type has its own
  # consecutive numbering and authorized receipts can be consulted afterwards.
  class FakeWsfe
    attr_reader :authorized, :calls

    def initialize(last_number: 0)
      @last_numbers = Hash.new(last_number)
      @authorized = {}
      @calls = []
    end

    def last_authorized(receipt_type:, point_of_sale:)
      @calls << :last_authorized
      @last_numbers[receipt_type]
    end

    def authorize(receipt_type:, point_of_sale:, detail:)
      @calls << :authorize
      number = detail.fetch("CbteDesde")
      unless number == @last_numbers[receipt_type] + 1
        return [ { resultado: "R", cbte_desde: number.to_s, observaciones: { obs: { code: "10016", msg: "no es el próximo a autorizar" } }, errors: [] } ]
      end

      @last_numbers[receipt_type] = number
      cae = "7612345678#{number.to_s.rjust(4, "0")}"
      @authorized[[ receipt_type, number ]] = { cbte_desde: number.to_s, cod_autorizacion: cae, fch_vto: "20261005",
        imp_total: detail.fetch("ImpTotal").to_s("F"), doc_nro: detail.fetch("DocNro").to_s }
      [ { resultado: "A", cbte_desde: number.to_s, cae:, cae_fch_vto: "20261005", errors: [] } ]
    end

    def consult(receipt_type:, point_of_sale:, number:)
      @calls << :consult
      @authorized.fetch([ receipt_type, number ]) { raise Arca::Soap::ResponseError, [ { code: "602", msg: "No existen datos" } ] }
    end
  end

  RESPONSIBLE = { cuit: "30712345671", legal_name: "ACME S.A.", vat_condition: :responsible_registered, fiscal_address: "Av. Corrientes 1234, CABA",
    gross_income: "901-123456-7", activity_started_on: "2019-04-01" }.freeze
  MONOTRIBUTO = RESPONSIBLE.merge(cuit: "20111111112", legal_name: "María González", vat_condition: :monotributo).freeze
  COMPANY = { legal_name: "Cliente S.A.", document_type: :cuit, document_number: "30-12345678-1", vat_condition: :responsible_registered }.freeze
  CONSUMER = { document_type: :unidentified, document_number: 0, vat_condition: :final_consumer }.freeze

  def setup
    @wsfe = FakeWsfe.new(last_number: 151)
  end

  def test_prepares_an_a_receipt_with_net_prices_that_add_up
    draft = invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", quantity: 3, unit_price: 1000 } ], issue_date: Date.new(2026, 9, 25))

    assert_equal :invoice_a, draft.receipt_type.key
    assert_equal 152, draft.receipt_number
    assert_equal BigDecimal("2479.34"), draft.request.net_amount
    assert_equal BigDecimal("520.66"), draft.request.vat_amount
    assert_equal BigDecimal("3000"), draft.total_amount
    assert_equal BigDecimal("826.45"), draft.items.first.unit_price
    assert_equal draft.request.net_amount, draft.items.sum(&:subtotal)
  end

  def test_prepares_a_b_receipt_with_final_prices_for_final_consumers
    draft = invoicer.prepare(receiver: CONSUMER, items: [ { description: "Aviso", unit_price: 12_100 } ], issue_date: Date.new(2026, 9, 25))

    assert_equal :invoice_b, draft.receipt_type.key
    assert_equal BigDecimal("10000"), draft.request.net_amount
    assert_equal BigDecimal("2100"), draft.request.vat_amount
    assert_equal BigDecimal("12100"), draft.items.first.unit_price
  end

  def test_adds_vat_on_top_of_net_prices_when_asked
    draft = invoicer.prepare(receiver: CONSUMER, items: [ { description: "Aviso", unit_price: 10_000 } ], issue_date: Date.new(2026, 9, 25), prices_include_vat: false)

    assert_equal BigDecimal("12100"), draft.total_amount
    assert_equal BigDecimal("12100"), draft.items.first.subtotal
  end

  def test_monotributo_issuers_prepare_c_receipts_without_vat
    draft = invoicer(issuer: MONOTRIBUTO).prepare(receiver: COMPANY, items: [ { description: "Sesión", quantity: 4, unit_price: "21501.25" } ], issue_date: Date.new(2026, 9, 25))

    assert_equal :invoice_c, draft.receipt_type.key
    assert_equal BigDecimal("86005"), draft.total_amount
    assert_predicate draft.request.vat_amount, :zero?
  end

  def test_a_billed_period_makes_it_a_services_receipt
    period = { from: "2026-09-01", to: "2026-09-30", payment_due: "2026-10-10" }
    services = invoicer(issuer: MONOTRIBUTO).prepare(receiver: CONSUMER, items: [ { description: "Sesión", unit_price: 100 } ], issue_date: Date.new(2026, 9, 30), service_period: period)
    goods = invoicer(issuer: MONOTRIBUTO).prepare(receiver: CONSUMER, items: [ { description: "Libro", unit_price: 100 } ], issue_date: Date.new(2026, 9, 30),
      service_period: period, concept: :products)

    assert_equal :services, services.request.concept
    assert_equal :products, goods.request.concept
    assert_equal :services, Arca::Draft.from_h(JSON.parse(JSON.generate(services.to_h))).request.concept
  end

  def test_credit_notes_keep_the_period_but_never_fall_due_before_they_are_issued
    invoice = invoicer.authorize(invoicer.prepare(receiver: CONSUMER, items: [ { description: "Sesión", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 30),
      service_period: { from: "2026-09-01", to: "2026-09-30", payment_due: "2026-10-10" }))

    credit_note = invoicer.prepare_credit_note(invoice, issue_date: Date.new(2026, 10, 20))

    assert_equal :services, credit_note.request.concept
    assert_equal Date.new(2026, 9, 1), credit_note.service_period.from
    assert_equal Date.new(2026, 10, 20), credit_note.service_period.payment_due
  end

  def test_prints_the_branch_address_of_the_point_of_sale
    branch = invoicer(point_of_sale: { number: 4, commercial_address: "Rivadavia 100, Moreno" })
    fallback = invoicer(point_of_sale: { number: 4 })

    assert_includes text(branch.prepare(receiver: CONSUMER, items: [ { description: "Aviso", unit_price: 100 } ], issue_date: Date.new(2026, 9, 25)).pdf), "Rivadavia 100, Moreno"
    assert_includes text(fallback.prepare(receiver: CONSUMER, items: [ { description: "Aviso", unit_price: 100 } ], issue_date: Date.new(2026, 9, 25)).pdf), "Av. Corrientes 1234, CABA"
  end

  def test_authorizes_a_prepared_receipt
    receipt = invoicer.authorize(invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 25)))

    assert_equal 152, receipt.number
    assert_equal "76123456780152", receipt.cae
    refute_predicate receipt, :recovered?
    assert_includes text(receipt.pdf), "76123456780152"
  end

  def test_retrying_an_already_authorized_draft_recovers_it_instead_of_issuing_twice
    draft = invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 25))
    first = invoicer.authorize(draft)

    retried = invoicer.authorize(Arca::Draft.from_h(JSON.parse(JSON.generate(draft.to_h))))

    assert_predicate retried, :recovered?
    assert_equal first.cae, retried.cae
    assert_equal 1, @wsfe.authorized.size
  end

  def test_reports_a_number_taken_by_another_receipt
    stale = invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 25))
    invoicer.authorize(invoicer.prepare(receiver: COMPANY, items: [ { description: "Otro", unit_price: 500 } ], issue_date: Date.new(2026, 9, 25), receipt_number: 152))

    error = assert_raises(Arca::ReceiptNumberTaken) { invoicer.authorize(stale) }
    assert_equal [ "10016" ], error.codes
  end

  def test_keeps_the_original_rejection_when_the_number_was_never_used
    draft = invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 25), receipt_number: 160)

    error = assert_raises(Arca::Rejection) { invoicer.authorize(draft) }
    refute_kind_of Arca::ReceiptNumberTaken, error
  end

  def test_rejects_drafts_from_another_point_of_sale
    draft = invoicer(point_of_sale: { number: 5 }).prepare(receiver: CONSUMER, items: [ { description: "Aviso", unit_price: 100 } ], issue_date: Date.new(2026, 9, 25))

    assert_raises(ArgumentError) { invoicer.authorize(draft) }
  end

  def test_credits_a_whole_invoice_with_the_same_letter_and_association
    invoice = invoicer.authorize(invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 25)))

    credit_note = invoicer.prepare_credit_note(invoice, issue_date: Date.new(2026, 9, 26))

    assert_equal :credit_note_a, credit_note.receipt_type.key
    assert_equal invoice.total_amount, credit_note.total_amount
    assert_equal [ Arca::Request::AssociatedReceipt.new(receipt_type: 1, point_of_sale: 4, receipt_number: 152) ], credit_note.request.associated_receipts
    assert_includes text(credit_note.pdf), "Factura A 00004-00000152"
  end

  def test_credits_part_of_an_invoice_but_never_more_than_its_total
    invoice = invoicer.authorize(invoicer.prepare(receiver: CONSUMER, items: [ { description: "Aviso", quantity: 2, unit_price: 1210 } ], issue_date: Date.new(2026, 9, 25)))

    partial = invoicer.prepare_credit_note(invoice, issue_date: Date.new(2026, 9, 26), items: [ { description: "Aviso", unit_price: 1210 } ])

    assert_equal BigDecimal("1210"), partial.total_amount
    assert_raises(Arca::InvalidRequest) { invoicer.prepare_credit_note(invoice, issue_date: Date.new(2026, 9, 26), items: [ { description: "Aviso", unit_price: 5000 } ]) }
  end

  def test_debits_an_invoice_with_its_letter_receiver_and_period
    invoice = invoicer.authorize(invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210 } ], issue_date: Date.new(2026, 9, 30),
      service_period: { from: "2026-09-01", to: "2026-09-30", payment_due: "2026-10-10" }))

    debit_note = invoicer.prepare_debit_note(invoice, issue_date: Date.new(2026, 10, 20), items: [ { description: "Recargo por mora", unit_price: 121 } ])
    issued = invoicer.authorize(debit_note)

    assert_equal :debit_note_a, debit_note.receipt_type.key
    assert_equal BigDecimal("121"), debit_note.total_amount
    assert_equal [ Arca::Request::AssociatedReceipt.new(receipt_type: 1, point_of_sale: 4, receipt_number: 152) ], debit_note.request.associated_receipts
    assert_equal Date.new(2026, 10, 20), debit_note.service_period.payment_due
    assert_equal 152, issued.number
    assert_includes text(issued.pdf), "NOTA DE DÉBITO"
  end

  def test_verifies_the_point_of_sale_only_where_arca_registers_them
    assert_nil invoicer.verify_point_of_sale!
  end

  def test_rebuilds_an_issued_receipt_from_its_stored_hash
    receipt = invoicer.authorize(invoicer.prepare(receiver: COMPANY, items: [ { description: "Aviso", unit_price: 1210, discount_percent: 10 } ], issue_date: Date.new(2026, 9, 25),
      service_period: { from: "2026-09-01", to: "2026-09-30", payment_due: "2026-10-10" }))

    rebuilt = Arca::IssuedReceipt.from_h(JSON.parse(JSON.generate(receipt.to_h)))

    assert_equal receipt.to_h, rebuilt.to_h
    assert_equal receipt.qr.payload, rebuilt.qr.payload
  end

  def test_prefills_the_issuer_from_the_padron
    person = Arca::PadronClient::Person.new(tax_id: "20111111112", legal_name: "GONZALEZ MARIA", fiscal_address: "AV CORRIENTES 1234, CABA",
      vat_condition: :monotributo, activity_started_on: Date.new(2019, 4, 1), active: true)

    issuer = Arca::Issuer.from_padron(person, gross_income: "20111111112")

    assert_equal :monotributo, issuer.vat_condition
    assert_equal "AV CORRIENTES 1234, CABA", issuer.fiscal_address
  end

  private

  def invoicer(issuer: RESPONSIBLE, point_of_sale: { number: 4, commercial_address: "Rivadavia 100, Moreno" })
    issuer = Arca::Issuer.new(**issuer)
    client = Arca::Client.new(credentials: homologation_credentials, issuer_cuit: issuer.cuit, point_of_sale: point_of_sale.fetch(:number), wsfe: @wsfe)
    Arca::Invoicer.new(credentials: homologation_credentials, issuer:, point_of_sale:, client:)
  end

  def text(pdf) = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")
end
