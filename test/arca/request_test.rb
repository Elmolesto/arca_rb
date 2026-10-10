require "test_helper"

class Arca::RequestTest < Minitest::Test
  def test_accepts_a_c_invoice_without_vat
    request = build(receipt_type: :invoice_c, receiver: Arca::Request::Receiver.unidentified_final_consumer, vat_amount: 0)

    assert_equal BigDecimal("100"), request.total_amount
    refute_predicate request, :vat_discriminated?
  end

  def test_rejects_vat_on_a_c_receipt
    error = assert_raises(Arca::InvalidRequest) { build(receipt_type: 11, vat_amount: 21) }
    assert_equal "Los comprobantes C no discriminan IVA", error.message
  end

  def test_rejects_an_invalid_receiver_document
    receiver = { document_type: :cuil, document_number: "20123456789", vat_condition: :vat_exempt }

    error = assert_raises(Arca::InvalidRequest) { build(receipt_type: :invoice_b, receiver:) }
    assert_equal "El documento fiscal del receptor no es válido", error.message
  end

  def test_rejects_receivers_arca_does_not_accept_for_the_letter
    assert_raises(Arca::InvalidRequest) { build(receipt_type: :invoice_a, receiver: receiver(vat_condition: :vat_exempt)) }
    assert_raises(Arca::InvalidRequest) { build(receipt_type: :invoice_b, receiver: receiver(vat_condition: :responsible_registered)) }
  end

  def test_requires_a_same_letter_invoice_for_a_credit_note
    associated = Arca::Request::AssociatedReceipt.new(receipt_type: 11, point_of_sale: 3, receipt_number: 42)
    request = build(receipt_type: 13, vat_amount: 0, associated_receipts: [ associated ])

    assert_predicate request, :credit_note?
    assert_equal [ associated ], request.associated_receipts
    assert_raises(Arca::InvalidRequest) do
      build(receipt_type: 13, vat_amount: 0, associated_receipts: [ { receipt_type: 6, point_of_sale: 3, receipt_number: 42 } ])
    end
  end

  def test_rejects_a_credit_note_without_an_invoice
    assert_raises(Arca::InvalidRequest) { build(receipt_type: 3) }
  end

  def test_rejects_associations_on_an_invoice
    assert_raises(Arca::InvalidRequest) do
      build(receipt_type: 1, associated_receipts: [ { receipt_type: 1, point_of_sale: 3, receipt_number: 42 } ])
    end
  end

  def test_services_require_the_billed_period
    error = assert_raises(Arca::InvalidRequest) { build(concept: :services) }
    assert_equal "Los comprobantes de servicios necesitan el período facturado y el vencimiento del pago", error.message

    request = build(concept: :services, service_period: { from: "2026-08-01", to: "2026-08-31", payment_due: "2026-08-20" })
    assert_equal 2, request.concept_code
    assert_equal Date.new(2026, 8, 31), request.service_period.to
  end

  def test_rejects_a_payment_due_before_the_receipt
    assert_raises(Arca::InvalidRequest) { build(concept: :services, service_period: { from: "2026-08-01", to: "2026-08-31", payment_due: "2026-08-10" }) }
  end

  def test_rejects_a_period_that_ends_before_it_starts
    assert_raises(Arca::InvalidRequest) { build(concept: :services, service_period: { from: "2026-08-31", to: "2026-08-01", payment_due: "2026-09-10" }) }
  end

  def test_debit_notes_reference_an_invoice_of_the_same_letter
    request = build(receipt_type: :debit_note_a, associated_receipts: [ { receipt_type: 1, point_of_sale: 3, receipt_number: 42 } ])

    assert_predicate request, :debit_note?
    assert_raises(Arca::InvalidRequest) { build(receipt_type: :debit_note_a) }
    assert_raises(Arca::InvalidRequest) { build(receipt_type: :debit_note_a, associated_receipts: [ { receipt_type: 6, point_of_sale: 3, receipt_number: 42 } ]) }
  end

  def test_credit_notes_may_reference_a_debit_note_but_not_another_credit_note
    assert build(receipt_type: :credit_note_a, associated_receipts: [ { receipt_type: 2, point_of_sale: 3, receipt_number: 5 } ])
    assert_raises(Arca::InvalidRequest) { build(receipt_type: :credit_note_a, associated_receipts: [ { receipt_type: 3, point_of_sale: 3, receipt_number: 5 } ]) }
  end

  def test_invalid_requests_are_argument_errors
    assert_raises(ArgumentError) { build(receipt_number: 0) }
  end

  private

  def receiver(vat_condition: :responsible_registered)
    Arca::Request::Receiver.new(document_type: 80, document_number: "30123456781", vat_condition:)
  end

  def build(receipt_type: :invoice_a, receipt_number: 1, receiver: self.receiver, net_amount: 100, vat_amount: 21, associated_receipts: [], **options)
    Arca::Request.new(receipt_type:, receipt_number:, receiver:, net_amount:, vat_amount:, issue_date: Date.new(2026, 8, 15), associated_receipts:, **options)
  end
end
