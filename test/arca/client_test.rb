require "test_helper"

class Arca::ClientTest < Minitest::Test
  # Stands in for Arca::Wsfe, answering with the hashes it would parse.
  class FakeWsfe
    attr_reader :calls

    def initialize(last_number: 0, receipt: nil, authorization: nil)
      @last_number = last_number
      @receipt = receipt
      @authorization = authorization
      @calls = []
    end

    def last_authorized(**arguments)
      @calls << [ :last_authorized, arguments ]
      @last_number
    end

    def consult(**arguments)
      @calls << [ :consult, arguments ]
      raise Arca::Soap::ResponseError, [ { code: "602", msg: "No existen datos en nuestros registros" } ] unless @receipt

      @receipt
    end

    def authorize(**arguments)
      @calls << [ :authorize, arguments ]
      @authorization || [ { resultado: "A", cbte_desde: arguments.fetch(:detail).fetch("CbteDesde").to_s, cae: "12345678901234", cae_fch_vto: "20260825", errors: [] } ]
    end

    def detail = @calls.last.last.fetch(:detail)
  end

  def test_checks_the_connection_for_the_delegating_issuer
    wsfe = FakeWsfe.new(last_number: 17)
    connection = client(wsfe:).test_connection

    assert_equal "20333444556", connection.issuer_cuit
    assert_equal 4, connection.point_of_sale
    assert_equal 11, connection.receipt_type
    assert_equal 17, connection.last_authorized_number
    assert_equal [ [ :last_authorized, { receipt_type: 11, point_of_sale: 4 } ] ], wsfe.calls
  end

  def test_computes_the_next_receipt_number
    assert_equal 23, client(wsfe: FakeWsfe.new(last_number: 22)).next_receipt_number(receipt_type: 6)
  end

  def test_authorizes_a_credit_note_with_its_original_invoice_in_wsdl_order
    wsfe = FakeWsfe.new
    request = Arca::Request.new(
      receipt_type: 3,
      receipt_number: 9,
      receiver: { document_type: 80, document_number: "30123456781", vat_condition: :responsible_registered },
      net_amount: 100,
      vat_amount: 21,
      issue_date: Date.new(2026, 8, 15),
      associated_receipts: [ { receipt_type: 1, point_of_sale: 4, receipt_number: 42 } ]
    )

    authorization = client(wsfe:).authorize(request:)

    assert_equal Arca::Client::Authorization.new(number: 9, cae: "12345678901234", expires_on: Date.new(2026, 8, 25)), authorization
    assert_equal({ receipt_type: 3, point_of_sale: 4 }, wsfe.calls.first.last.except(:detail))
    assert_equal(
      {
        "Concepto" => 1, "DocTipo" => 80, "DocNro" => 30_123_456_781, "CbteDesde" => 9, "CbteHasta" => 9, "CbteFch" => Date.new(2026, 8, 15),
        "ImpTotal" => BigDecimal("121"), "ImpTotConc" => 0, "ImpNeto" => BigDecimal("100"), "ImpOpEx" => 0, "ImpTrib" => 0, "ImpIVA" => BigDecimal("21"),
        "MonId" => "PES", "MonCotiz" => 1, "CondicionIVAReceptorId" => 1,
        "CbtesAsoc" => { "CbteAsoc" => [ { "Tipo" => 1, "PtoVta" => 4, "Nro" => 42 } ] },
        "Iva" => { "AlicIva" => [ { "Id" => 5, "BaseImp" => BigDecimal("100"), "Importe" => BigDecimal("21") } ] }
      },
      wsfe.detail
    )
    assert_equal %w[Concepto DocTipo DocNro CbteDesde CbteHasta CbteFch ImpTotal ImpTotConc ImpNeto ImpOpEx ImpTrib ImpIVA MonId MonCotiz CondicionIVAReceptorId CbtesAsoc Iva],
      wsfe.detail.keys
  end

  def test_sends_the_vat_breakdown_on_b_receipts_to_unidentified_final_consumers
    wsfe = FakeWsfe.new
    request = Arca::Request.new(receipt_type: 6, receipt_number: 43, receiver: Arca::Request::Receiver.unidentified_final_consumer, net_amount: 100, vat_amount: "10.5", vat_rate: "10.5", issue_date: Date.new(2026, 8, 3))

    client(wsfe:).authorize(request:)

    assert_equal [ 99, 0, 5 ], wsfe.detail.values_at("DocTipo", "DocNro", "CondicionIVAReceptorId")
    assert_equal [ { "Id" => 4, "BaseImp" => BigDecimal("100"), "Importe" => BigDecimal("10.5") } ], wsfe.detail.dig("Iva", "AlicIva")
  end

  def test_sends_the_billed_period_on_services_receipts_before_the_currency
    wsfe = FakeWsfe.new
    request = Arca::Request.new(receipt_type: 11, receipt_number: 43, receiver: Arca::Request::Receiver.unidentified_final_consumer, net_amount: 100, vat_amount: 0,
      issue_date: Date.new(2026, 9, 1), concept: :services, service_period: { from: "2026-08-01", to: "2026-08-31", payment_due: "2026-09-10" })

    client(wsfe:).authorize(request:)

    assert_equal 2, wsfe.detail.fetch("Concepto")
    assert_equal [ Date.new(2026, 8, 1), Date.new(2026, 8, 31), Date.new(2026, 9, 10) ], wsfe.detail.values_at("FchServDesde", "FchServHasta", "FchVtoPago")
    assert_equal %w[ImpIVA FchServDesde FchServHasta FchVtoPago MonId], wsfe.detail.keys[11, 5]
  end

  def test_products_receipts_never_send_the_printed_period
    wsfe = FakeWsfe.new
    request = Arca::Request.new(receipt_type: 11, receipt_number: 43, receiver: Arca::Request::Receiver.unidentified_final_consumer, net_amount: 100, vat_amount: 0,
      issue_date: Date.new(2026, 9, 1), service_period: { from: "2026-08-01", to: "2026-08-31", payment_due: "2026-09-10" })

    client(wsfe:).authorize(request:)

    assert_equal 1, wsfe.detail.fetch("Concepto")
    refute wsfe.detail.key?("FchServDesde")
    refute wsfe.detail.key?("Iva")
  end

  def test_keeps_provider_text_out_of_the_rejection_message
    rejected = [ { resultado: "R", cbte_desde: "43", observaciones: { obs: { code: "10016", msg: "Detalle sensible del proveedor" } }, errors: [ { code: "10048", msg: "Otro detalle" } ] } ]
    request = Arca::Request.new(receipt_type: 11, receipt_number: 43, receiver: Arca::Request::Receiver.unidentified_final_consumer, net_amount: 100, vat_amount: 0, issue_date: Date.new(2026, 8, 3))

    error = assert_raises(Arca::Rejection) { client(wsfe: FakeWsfe.new(authorization: rejected)).authorize(request:) }

    assert_equal %w[10016 10048], error.codes
    assert_equal "ARCA rechazó la autorización del comprobante (códigos ARCA: 10016, 10048)", error.message
    assert_equal [ "Detalle sensible del proveedor", "Otro detalle" ], error.diagnostics
  end

  def test_reports_codes_and_diagnostics_for_a_failed_query
    wsfe = Object.new
    wsfe.define_singleton_method(:last_authorized) { |**| raise Arca::Soap::ResponseError, [ { code: "10001", msg: "detalle interno" } ] }

    error = assert_raises(Arca::Rejection) { client(wsfe:).test_connection }

    assert_equal [ "10001" ], error.codes
    assert_equal "ARCA rechazó la consulta de conexión (códigos ARCA: 10001)", error.message
    assert_equal [ "10001: detalle interno" ], error.diagnostics
  end

  def test_network_failures_stay_transient
    wsfe = Object.new
    wsfe.define_singleton_method(:last_authorized) { |**| raise Arca::TransientError, "ARCA no está disponible" }

    assert_raises(Arca::TransientError) { client(wsfe:).last_authorized_receipt(receipt_type: 11) }
  end

  def test_reconciles_an_existing_receipt
    wsfe = FakeWsfe.new(receipt: { cbte_desde: "43", cod_autorizacion: "12345678901234", fch_vto: "20260813", imp_total: "121", doc_nro: "30123456781" })

    receipt = client(wsfe:).consult_receipt(receipt_type: 6, receipt_number: 43)

    assert_equal Arca::Client::Receipt.new(number: 43, cae: "12345678901234", expires_on: Date.new(2026, 8, 13), total: BigDecimal("121"), receiver_document_number: "30123456781"), receipt
  end

  def test_returns_nil_for_a_receipt_arca_does_not_have
    assert_nil client(wsfe: FakeWsfe.new).consult_receipt(receipt_type: 6, receipt_number: 43)
  end

  def test_lists_the_points_of_sale_enabled_in_arca
    wsfe = FakeWsfe.new
    def wsfe.points_of_sale = [ { nro: "4", emision_tipo: "CAE", bloqueado: "N", fch_baja: "NULL" }, { nro: "5", emision_tipo: "CAE", bloqueado: "S", fch_baja: "20260101" } ]

    points = client(wsfe:).points_of_sale

    assert_equal [ 4, 5 ], points.map(&:number)
    assert_predicate points.first, :active?
    assert_predicate points.last, :blocked?
    assert_equal Date.new(2026, 1, 1), points.last.removed_on
  end

  def test_verifies_the_point_of_sale_in_production
    wsfe = FakeWsfe.new
    def wsfe.points_of_sale = [ { nro: "4", emision_tipo: "CAE", bloqueado: "N", fch_baja: "NULL" }, { nro: "5", emision_tipo: "CAE", bloqueado: "S", fch_baja: "NULL" } ]
    production = ->(point_of_sale) { Arca::Client.new(credentials: production_credentials, issuer_cuit: "20-33344455-6", point_of_sale:, wsfe:) }

    assert_equal 4, production.(4).verify_point_of_sale!.number
    assert_includes assert_raises(Arca::ConfigurationError) { production.(5).verify_point_of_sale! }.message, "bloqueado"
    assert_includes assert_raises(Arca::ConfigurationError) { production.(9).verify_point_of_sale! }.message, "no está habilitado"
  end

  def test_no_points_of_sale_is_an_empty_list
    wsfe = FakeWsfe.new
    def wsfe.points_of_sale = raise(Arca::Soap::ResponseError, [ { code: "602", msg: "Sin Resultados" } ])

    assert_empty client(wsfe:).points_of_sale
  end

  def test_validates_the_configuration_before_building_the_real_service
    client = Arca::Client.new(credentials: homologation_credentials, point_of_sale: 4)

    assert_raises(Arca::ConfigurationError) { client.last_authorized_receipt(receipt_type: 11) }
  end

  def test_rejects_a_non_positive_point_of_sale
    assert_raises(Arca::ConfigurationError) { client(wsfe: FakeWsfe.new, point_of_sale: 0).test_connection }
  end

  private

  def client(wsfe:, point_of_sale: 4)
    Arca::Client.new(credentials: homologation_credentials(cuit: "20111222333"), issuer_cuit: "20-33344455-6", point_of_sale:, wsfe:)
  end
end
