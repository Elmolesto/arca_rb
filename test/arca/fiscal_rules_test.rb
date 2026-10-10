require "test_helper"

class Arca::FiscalRulesTest < Minitest::Test
  def test_validates_the_cuit_and_cuil_check_digit
    assert Arca::Identity.valid?(document_type: :cuit, document_number: "30-12345678-1")
    assert Arca::Identity.valid?(document_type: 86, document_number: "20-12345678-6")
    refute Arca::Identity.valid?(document_type: :cuit, document_number: "30-12345678-2")
    refute Arca::Identity.valid?(document_type: 86, document_number: "20123456789")
  end

  def test_normalizes_the_unidentified_final_consumer
    assert_equal({ type: :unidentified, number: "0" }, Arca::Identity.normalize(document_type: 99, document_number: "12345678"))
  end

  def test_accepts_vat_conditions_as_symbols_or_arca_ids
    assert_equal :monotributo, Arca::VatCondition.fetch(6)
    assert_equal 4, Arca::VatCondition.id_for("vat_exempt")
    refute Arca::VatCondition.valid?(99)
  end

  def test_monotributo_and_exempt_issuers_emit_c
    assert_equal 11, Arca::ReceiptType.for(issuer_vat_condition: :monotributo, receiver_vat_condition: :responsible_registered).code
    assert_equal 11, Arca::ReceiptType.for(issuer_vat_condition: :vat_exempt, receiver_vat_condition: :final_consumer).code
  end

  def test_responsible_registered_issuers_emit_a_or_b_by_receiver
    assert_equal 1, Arca::ReceiptType.for(issuer_vat_condition: :responsible_registered, receiver_vat_condition: :responsible_registered).code
    assert_equal 1, Arca::ReceiptType.for(issuer_vat_condition: :responsible_registered, receiver_vat_condition: :monotributo).code
    assert_equal 6, Arca::ReceiptType.for(issuer_vat_condition: :responsible_registered, receiver_vat_condition: :final_consumer).code
    assert_equal 6, Arca::ReceiptType.for(issuer_vat_condition: :responsible_registered, receiver_vat_condition: 4).code
  end

  def test_names_the_missing_vat_condition
    error = assert_raises(Arca::InvalidRequest) { Arca::ReceiptType.for(issuer_vat_condition: nil, receiver_vat_condition: :final_consumer) }
    assert_equal "Falta la condición frente al IVA del emisor", error.message
  end

  def test_selects_credit_notes_with_the_letter_of_their_invoice
    assert_equal 3, Arca::ReceiptType.credit_note_for(1).code
    assert_equal 8, Arca::ReceiptType.credit_note_for(:invoice_b).code
    assert_equal 13, Arca::ReceiptType.credit_note_for(11).code
    assert_equal 8, Arca::ReceiptType.for(issuer_vat_condition: :responsible_registered, receiver_vat_condition: :final_consumer, kind: :credit_note).code
    assert_raises(Arca::InvalidRequest) { Arca::ReceiptType.credit_note_for(3) }
  end

  def test_selects_debit_notes_with_the_letter_of_their_invoice
    assert_equal [ 2, 7, 12 ], [ 1, 6, 11 ].map { |code| Arca::ReceiptType.debit_note_for(code).code }
    assert_equal "NOTA DE DÉBITO", Arca::ReceiptType.fetch(:debit_note_b).document_title
    assert_raises(Arca::InvalidRequest) { Arca::ReceiptType.debit_note_for(:debit_note_a) }
  end

  def test_splits_a_vat_inclusive_total_that_adds_up
    split = Arca::VatRate.split(total: "100")

    assert_equal BigDecimal("82.64"), split.fetch(:net_amount)
    assert_equal BigDecimal("17.36"), split.fetch(:vat_amount)
    assert_equal 5, Arca::VatRate.id_for(21)
    assert_equal 4, Arca::VatRate.id_for("10.5")
    assert_raises(Arca::InvalidRequest) { Arca::VatRate.id_for(19) }
  end
end
