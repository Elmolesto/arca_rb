require "test_helper"
require "pdf-reader"

class Arca::PdfTest < Minitest::Test
  ISSUER = { legal_name: "María González", cuit: "20111111112", fiscal_address: "Av. Corrientes 1234, CABA", vat_condition: :monotributo, activity_started_on: Date.new(2019, 4, 1) }.freeze
  CONSUMER = { document_type: :unidentified, document_number: 0, vat_condition: :final_consumer }.freeze

  def test_renders_an_authorized_receipt_with_cae_and_qr
    text, pages = read(Arca::Pdf.render(document(point_of_sale: 3, receipt_number: 152, cae: "76123456789012", cae_expires_on: Date.new(2026, 10, 5))))

    assert_equal 1, pages
    assert_includes text, "ORIGINAL"
    assert_includes text, "00003"
    assert_includes text, "00000152"
    assert_includes text, "76123456789012"
    assert_includes text, "Responsable Monotributo"
    assert_includes text, "$ 21.501,25"
    assert_includes text, "VEINTIÚN MIL QUINIENTOS UNO CON 25/100"
  end

  def test_renders_one_set_of_pages_per_copy
    _, pages = read(Arca::Pdf.render(document(point_of_sale: 3, receipt_number: 1, cae: "1", cae_expires_on: Date.new(2026, 10, 5)), copies: %i[original duplicate triplicate]))

    assert_equal 3, pages
  end

  def test_renders_a_draft_without_fiscal_data
    text, = read(Arca::Pdf.render(document, copies: %i[original duplicate]))

    assert_includes text, "SIN VALIDEZ FISCAL"
    refute_includes text, "CAE N°"
    refute_includes text, "DUPLICADO"
  end

  def test_renders_a_draft_as_a_proforma_of_the_app
    text, = read(Arca::Pdf.render(document, proforma: { title: "Orden de compra", number: 1234 }))

    assert_includes text, "ORDEN DE COMPRA · SIN VALIDEZ FISCAL"
    assert_includes text, "NO FISCAL"
    assert_includes text, "1234"
    refute_includes text, "BORRADOR"
    refute_includes text, "Punto de Venta"
    refute_includes text, "CAE N°"
  end

  def test_an_authorized_receipt_cannot_be_a_proforma
    authorized = document(point_of_sale: 3, receipt_number: 1, cae: "1", cae_expires_on: Date.new(2026, 10, 5))

    assert_raises(ArgumentError) { Arca::Pdf.render(authorized, proforma: { title: "Orden de compra" }) }
  end

  def test_paginates_long_item_lists_and_keeps_totals_on_the_last_page
    items = 40.times.map { |index| { description: "Ítem #{index + 1}", unit_price: 100 } }
    pdf = Arca::Pdf.render(document(items:, net_amount: 4_000, point_of_sale: 3, receipt_number: 1, cae: "1", cae_expires_on: Date.new(2026, 10, 5)))
    reader = PDF::Reader.new(StringIO.new(pdf))

    assert_operator reader.page_count, :>, 1
    assert_includes reader.pages.last.text, "Ítem 40"
    assert_includes reader.pages.last.text, "Importe Total"
    refute_includes reader.pages.first.text, "Importe Total"
    assert_includes reader.pages.last.text, "Pág. #{reader.page_count}/#{reader.page_count}"
  end

  def test_discloses_contained_vat_on_b_receipts
    document = Arca::Pdf::Document.new(receipt_type: :invoice_b, issued_on: "2026-09-25", issuer: ISSUER.merge(vat_condition: :responsible_registered), receiver: CONSUMER,
      items: [ { description: "Aviso", unit_price: 12_100 } ], **Arca::VatRate.split(total: 12_100), point_of_sale: 3, receipt_number: 7, cae: "1", cae_expires_on: Date.new(2026, 10, 5))
    text, = read(Arca::Pdf.render(document))

    assert_equal [ Arca::Pdf::VatLine.new(rate: 21, base: 10_000, amount: 2_100) ], document.vat_lines
    assert_includes text, "Ley 27.743"
    assert_includes text, "$ 2.100,00"
    refute document.qr.payload.key?(:tipoDocRec)
  end

  def test_discloses_contained_vat_only_to_final_consumers
    exempt = { legal_name: "Fundación", document_type: :cuit, document_number: "30123456781", vat_condition: :vat_exempt }
    document = Arca::Pdf::Document.new(receipt_type: :invoice_b, issued_on: "2026-09-25", issuer: ISSUER.merge(vat_condition: :responsible_registered), receiver: exempt,
      items: [ { description: "Aviso", unit_price: 12_100 } ], **Arca::VatRate.split(total: 12_100))
    text, = read(Arca::Pdf.render(document))

    refute_includes text, "Ley 27.743"
  end

  def test_requires_the_cae_expiration_on_authorized_receipts
    assert_raises(ArgumentError) { document(point_of_sale: 3, receipt_number: 1, cae: "1") }
  end

  def test_formats_argentine_amounts_and_words
    assert_equal "$ 1.234.567,89", Arca::Pdf::Format.money("1234567.891")
    assert_equal "US$ 0,50", Arca::Pdf::Format.money("0.5", symbol: "US$")
    assert_equal "20-11111111-2", Arca::Pdf::Format.cuit("20111111112")
    assert_equal "10,5%", Arca::Pdf::Format.percentage("10.5")
    assert_equal "veintiún millones doscientos un mil dieciséis", Arca::Pdf::Format.words(21_201_016)
    assert_equal "un millón ciento veintidós", Arca::Pdf::Format.words(1_000_122)
  end

  private

  def document(items: [ { description: "Sesión", unit_price: "21501.25" } ], net_amount: "21501.25", **options)
    Arca::Pdf::Document.new(receipt_type: :invoice_c, issued_on: "2026-09-25", issuer: ISSUER, receiver: CONSUMER, items:, net_amount:, **options)
  end

  def read(pdf)
    reader = PDF::Reader.new(StringIO.new(pdf))
    [ reader.pages.map(&:text).join("\n"), reader.page_count ]
  end
end
