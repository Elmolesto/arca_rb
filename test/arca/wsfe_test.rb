require "test_helper"

class Arca::WsfeTest < Minitest::Test
  NS = { "f" => Arca::Wsfe::NAMESPACE }.freeze

  def test_asks_for_the_last_authorized_number_with_auth
    transport = FakeTransport.new(response("FECompUltimoAutorizado", "<PtoVta>4</PtoVta><CbteTipo>11</CbteTipo><CbteNro>151</CbteNro>"))

    assert_equal 151, wsfe(transport).last_authorized(receipt_type: 11, point_of_sale: 4)

    request = transport.requests.first
    assert_equal "https://wswhomo.afip.gov.ar/wsfev1/service.asmx", request[:url]
    assert_equal %("http://ar.gov.afip.dif.FEV1/FECompUltimoAutorizado"), request[:headers].fetch("SOAPAction")
    assert_equal %w[TOKEN SIGN 30712345671], %w[Token Sign Cuit].map { |name| request[:xml].at_xpath("//f:Auth/f:#{name}", NS).text }
    assert_equal "4", request[:xml].at_xpath("//f:FECompUltimoAutorizado/f:PtoVta", NS).text
    assert_nil request[:ciphers]
  end

  def test_sends_the_receipt_in_wsdl_order
    transport = FakeTransport.new(response("FECAESolicitar", <<~XML))
      <FeCabResp><Cuit>30712345671</Cuit><PtoVta>4</PtoVta><CbteTipo>1</CbteTipo><Resultado>A</Resultado></FeCabResp>
      <FeDetResp><FECAEDetResponse><Concepto>1</Concepto><DocTipo>80</DocTipo><DocNro>30123456781</DocNro><CbteDesde>152</CbteDesde><CbteHasta>152</CbteHasta>
        <CbteFch>20260925</CbteFch><Resultado>A</Resultado><CAE>76123456789012</CAE><CAEFchVto>20261005</CAEFchVto></FECAEDetResponse></FeDetResp>
    XML
    detail = { "Concepto" => 1, "DocTipo" => 80, "DocNro" => 30_123_456_781, "CbteDesde" => 152, "CbteHasta" => 152, "CbteFch" => Date.new(2026, 9, 25),
      "ImpTotal" => BigDecimal("121"), "ImpNeto" => BigDecimal("100"), "ImpIVA" => BigDecimal("21"), "MonId" => "PES", "MonCotiz" => 1, "CondicionIVAReceptorId" => 1,
      "Iva" => { "AlicIva" => [ { "Id" => 5, "BaseImp" => BigDecimal("100"), "Importe" => BigDecimal("21") } ] } }

    result = wsfe(transport).authorize(receipt_type: 1, point_of_sale: 4, detail:)

    assert_equal [ { concepto: "1", doc_tipo: "80", doc_nro: "30123456781", cbte_desde: "152", cbte_hasta: "152", cbte_fch: "20260925", resultado: "A",
      cae: "76123456789012", cae_fch_vto: "20261005", errors: [] } ], result
    xml = transport.requests.first[:xml]
    assert_equal %w[1 4 1], %w[CantReg PtoVta CbteTipo].map { |name| xml.at_xpath("//f:FeCabReq/f:#{name}", NS).text }
    assert_equal detail.keys, xml.at_xpath("//f:FECAEDetRequest", NS).element_children.map(&:name)
    assert_equal "20260925", xml.at_xpath("//f:CbteFch", NS).text
    assert_equal "121.00", xml.at_xpath("//f:ImpTotal", NS).text
    assert_equal "5", xml.at_xpath("//f:Iva/f:AlicIva/f:Id", NS).text
  end

  def test_returns_rejected_details_with_their_observations_and_errors
    transport = FakeTransport.new(response("FECAESolicitar", <<~XML))
      <FeCabResp><Resultado>R</Resultado></FeCabResp>
      <FeDetResp><FECAEDetResponse><CbteDesde>160</CbteDesde><Resultado>R</Resultado>
        <Observaciones><Obs><Code>10016</Code><Msg>El numero o fecha del comprobante no se corresponde con el proximo a autorizar.</Msg></Obs></Observaciones>
      </FECAEDetResponse></FeDetResp>
      <Errors><Err><Code>10048</Code><Msg>Otro error</Msg></Err></Errors>
    XML

    detail = wsfe(transport).authorize(receipt_type: 1, point_of_sale: 4, detail: {}).first

    assert_equal "10016", detail.dig(:observaciones, :obs, :code)
    assert_equal [ { code: "10048", msg: "Otro error" } ], detail.fetch(:errors)
  end

  def test_raises_header_errors_without_details
    transport = FakeTransport.new(response("FECAESolicitar", "<Errors><Err><Code>600</Code><Msg>ValidacionDeToken: No aparecio CUIT en lista de relaciones</Msg></Err></Errors>"))

    error = assert_raises(Arca::Soap::ResponseError) { wsfe(transport).authorize(receipt_type: 1, point_of_sale: 4, detail: {}) }
    assert error.code?(600)
  end

  def test_consults_a_receipt
    transport = FakeTransport.new(response("FECompConsultar", <<~XML))
      <ResultGet><Concepto>1</Concepto><DocTipo>80</DocTipo><DocNro>30123456781</DocNro><CbteDesde>152</CbteDesde><CbteHasta>152</CbteHasta><CbteFch>20260925</CbteFch>
        <ImpTotal>121</ImpTotal><Resultado>A</Resultado><CodAutorizacion>76123456789012</CodAutorizacion><EmisionTipo>CAE</EmisionTipo><FchVto>20261005</FchVto>
        <PtoVta>4</PtoVta><CbteTipo>1</CbteTipo></ResultGet>
    XML

    result = wsfe(transport).consult(receipt_type: 1, point_of_sale: 4, number: 152)

    assert_equal %w[152 76123456789012 20261005 121], result.values_at(:cbte_desde, :cod_autorizacion, :fch_vto, :imp_total)
    assert_equal %w[1 152 4], %w[CbteTipo CbteNro PtoVta].map { |name| transport.requests.first[:xml].at_xpath("//f:FeCompConsReq/f:#{name}", NS).text }
  end

  def test_reports_a_missing_receipt_as_602
    transport = FakeTransport.new(response("FECompConsultar", "<Errors><Err><Code>602</Code><Msg>No existen datos en nuestros registros para los parametros ingresados.</Msg></Err></Errors>"))

    error = assert_raises(Arca::Soap::ResponseError) { wsfe(transport).consult(receipt_type: 1, point_of_sale: 4, number: 999) }
    assert error.code?(602)
  end

  def test_production_lowers_the_openssl_security_level
    transport = FakeTransport.new(response("FECompUltimoAutorizado", "<CbteNro>1</CbteNro>"))
    credentials = production_credentials

    Arca::Wsfe.new(credentials:, cuit: "30712345671", transport:, wsaa: FakeWsaa.new).last_authorized(receipt_type: 11, point_of_sale: 4)

    assert_equal "https://servicios1.afip.gov.ar/wsfev1/service.asmx", transport.requests.first[:url]
    assert_equal "DEFAULT@SECLEVEL=1", transport.requests.first[:ciphers]
  end

  private

  def wsfe(transport) = Arca::Wsfe.new(credentials: homologation_credentials, cuit: "30712345671", transport:, wsaa: FakeWsaa.new)

  def response(operation, inner)
    FakeTransport.envelope(%(<#{operation}Response xmlns="#{Arca::Wsfe::NAMESPACE}"><#{operation}Result>#{inner}</#{operation}Result></#{operation}Response>))
  end
end
