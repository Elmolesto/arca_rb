require "test_helper"

class Arca::QrTest < Minitest::Test
  def test_builds_the_arca_payload_with_numeric_fields
    qr = Arca::Qr.new(
      issued_on: "2026-08-15",
      issuer_cuit: "20-11111111-2",
      point_of_sale: "3",
      receipt_type: :invoice_b,
      receipt_number: "42",
      total: "121.50",
      cae: "12345678901234",
      receiver_document_type: :cuit,
      receiver_document_number: "30-12345678-1",
      exchange_rate: "1"
    )

    assert_equal(
      { ver: 1, fecha: "2026-08-15", cuit: 20111111112, ptoVta: 3, tipoCmp: 6, nroCmp: 42, importe: 121.5, moneda: "PES", ctz: 1.0,
        tipoDocRec: 80, nroDocRec: 30123456781, tipoCodAut: "E", codAut: 12345678901234 },
      qr.payload
    )
    assert qr.url.start_with?("https://www.arca.gob.ar/fe/qr/?p=")
    assert qr.png.string.start_with?("\x89PNG".b)
  end

  def test_omits_the_receiver_when_unknown
    qr = Arca::Qr.new(issued_on: Date.new(2026, 8, 15), issuer_cuit: "20111111112", point_of_sale: 3, receipt_type: 11, receipt_number: 1, total: 100, cae: "1")

    refute qr.payload.key?(:tipoDocRec)
    refute qr.payload.key?(:nroDocRec)
  end
end
