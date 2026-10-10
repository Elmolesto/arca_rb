require "test_helper"

class Arca::PadronTest < Minitest::Test
  def test_queries_get_persona_with_unqualified_parameters
    transport = FakeTransport.new(FakeTransport.envelope(<<~XML))
      <ns2:getPersonaResponse xmlns:ns2="http://a5.soap.ws.server.puc.sr/"><personaReturn>
        <datosGenerales><apellido>ARGÜELLO</apellido><estadoClave>ACTIVO</estadoClave><idPersona>20221124643</idPersona>
          <domicilioFiscal><codPostal>3334</codPostal><descripcionProvincia>TUCUMAN</descripcionProvincia><direccion>CIUDADELA 789</direccion></domicilioFiscal></datosGenerales>
        <datosMonotributo><actividadMonotributista><periodo>202101</periodo></actividadMonotributista></datosMonotributo>
      </personaReturn></ns2:getPersonaResponse>
    XML

    persona = Arca::Padron.new(credentials: homologation_credentials, transport:, wsaa: FakeWsaa.new).get_persona("20221124643")

    assert_equal "20221124643", persona.dig(:datos_generales, :id_persona)
    assert_equal "TUCUMAN", persona.dig(:datos_generales, :domicilio_fiscal, :descripcion_provincia)
    xml = transport.requests.first[:xml]
    assert_equal "https://awshomo.afip.gov.ar/sr-padron/webservices/personaServiceA5", transport.requests.first[:url]
    assert_equal %w[TOKEN SIGN 20111111112 20221124643], %w[token sign cuitRepresentada idPersona].map { |name| xml.at_xpath("//p:getPersona/#{name}", "p" => Arca::Padron::NAMESPACE).text }
  end

  def test_authenticates_against_the_service_delegated_in_each_environment
    assert_equal "ws_sr_padron_a5", Arca::Padron::SERVICES.fetch(:homologation)
    assert_equal "ws_sr_constancia_inscripcion", Arca::Padron::SERVICES.fetch(:production)
  end

  def test_feeds_the_padron_client_end_to_end
    transport = FakeTransport.new(FakeTransport.envelope(<<~XML))
      <ns2:getPersonaResponse xmlns:ns2="http://a5.soap.ws.server.puc.sr/"><personaReturn>
        <datosGenerales><estadoClave>ACTIVO</estadoClave><fechaContratoSocial>2015-03-02T12:00:00-03:00</fechaContratoSocial><idPersona>30111111118</idPersona><razonSocial>ACME S.A.</razonSocial>
          <domicilioFiscal><direccion>SAN MARTIN 1</direccion><localidad>LUJAN</localidad></domicilioFiscal></datosGenerales>
        <datosRegimenGeneral><actividad><periodo>201503</periodo></actividad><impuesto><idImpuesto>30</idImpuesto></impuesto><impuesto><idImpuesto>20</idImpuesto></impuesto></datosRegimenGeneral>
      </personaReturn></ns2:getPersonaResponse>
    XML
    service = Arca::Padron.new(credentials: production_credentials, transport:, wsaa: FakeWsaa.new)

    person = Arca::PadronClient.new(credentials: production_credentials, service:).find_person(tax_id: "30-11111111-8")

    assert_equal :responsible_registered, person.vat_condition
    assert_equal "ACME S.A.", person.legal_name
    assert_equal Date.new(2015, 3, 1), person.activity_started_on
  end
end
