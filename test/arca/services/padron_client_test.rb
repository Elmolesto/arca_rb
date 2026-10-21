require "test_helper"

class Arca::PadronClientTest < Minitest::Test
  # Trimmed to what the client reads, shaped like the homologation registry's
  # answer for a test CUIT.
  RESPONSE = {
    datos_generales: {
      id_persona: 20221124643,
      razon_social: "ARGÜELLO ALFREDO OSCAR",
      estado_clave: "ACTIVO",
      domicilio_fiscal: { direccion: "CIUDADELA 789", localidad: "CATAMARCA", descripcion_provincia: "TUCUMAN", cod_postal: "3334" }
    },
    datos_monotributo: { actividad_monotributista: { periodo: "202101" } }
  }.freeze

  class FakeService
    attr_reader :asked_tax_ids

    def initialize(response)
      @response = response
      @asked_tax_ids = []
    end

    def get_persona(tax_id)
      @asked_tax_ids << tax_id
      @response
    end
  end

  def test_homologation_queries_the_test_cuit_for_the_person_kind
    service = FakeService.new(RESPONSE)
    client = Arca::PadronClient.new(credentials: homologation_credentials, service:)

    person = client.find_person(tax_id: "20-12345678-6")
    client.find_person(tax_id: "30123456781")

    assert_equal [ "20221124643", "30111111118" ], service.asked_tax_ids
    assert_equal "20221124643", person.tax_id
    assert_equal "ARGÜELLO ALFREDO OSCAR", person.legal_name
    assert_equal "CIUDADELA 789, CATAMARCA, TUCUMAN, 3334", person.fiscal_address
    assert_equal :monotributo, person.vat_condition
    assert_equal Date.new(2021, 1, 1), person.activity_started_on
    assert_predicate person, :active?
  end

  def test_production_queries_the_cuit_as_given
    service = FakeService.new(RESPONSE)

    Arca::PadronClient.new(credentials: production_credentials, service:).find_person(tax_id: "20-12345678-6")

    assert_equal [ "20123456786" ], service.asked_tax_ids
  end

  def test_reads_the_vat_condition_and_start_date_of_the_general_regime
    response = {
      datos_generales: { id_persona: 30111111118, razon_social: "ACME S.A.", estado_clave: "ACTIVO", fecha_alta: "2015-03-02", domicilio_fiscal: { direccion: "SAN MARTIN 1", localidad: "LUJAN" } },
      datos_regimen_general: { impuesto: [ { id_impuesto: 30 }, { id_impuesto: 20 } ] }
    }

    person = Arca::PadronClient.new(credentials: production_credentials, service: FakeService.new(response)).find_person(tax_id: "30111111118")

    assert_equal :responsible_registered, person.vat_condition
    assert_equal Date.new(2015, 3, 2), person.activity_started_on
  end

  def test_what_the_registry_does_not_inform_is_nil
    # Production answer for a natural person whose constancia carries only
    # identity: no address, VAT condition, VAT regime or activity date.
    response = {
      datos_generales: { id_persona: 27466828292, apellido: "BARRABINO", nombre: "MARTINA NICOLE", estado_clave: "ACTIVO" },
      metadata: {}
    }

    person = Arca::PadronClient.new(credentials: production_credentials, service: FakeService.new(response)).find_person(tax_id: "27466828292")

    assert_equal "27466828292", person.tax_id
    assert_equal "BARRABINO MARTINA NICOLE", person.legal_name
    assert_nil person.fiscal_address
    assert_nil person.vat_condition
    assert_nil person.activity_started_on
    assert_predicate person, :active?
  end

  def test_reports_a_cuit_without_fiscal_data
    service = FakeService.new({ error_constancia: { error: "No existe persona con ese Id" } })

    error = assert_raises(Arca::PadronClient::NotFound) { Arca::PadronClient.new(credentials: production_credentials, service:).find_person(tax_id: "30123456781") }
    assert_equal "ARCA no informó datos fiscales para el CUIT consultado", error.message
  end

  def test_reports_an_unknown_cuit_as_not_found
    service = Object.new
    service.define_singleton_method(:get_persona) { |_| raise Arca::Soap::ResponseError.new([ { code: "", msg: "No existe persona con ese Id" } ]) }

    assert_raises(Arca::PadronClient::NotFound) { Arca::PadronClient.new(credentials: production_credentials, service:).find_person(tax_id: "30123456781") }
  end

  def test_other_registry_faults_are_rejections
    service = Object.new
    service.define_singleton_method(:get_persona) { |_| raise Arca::Soap::ResponseError.new([ { code: "", msg: "Computador no autorizado a acceder al servicio" } ]) }

    error = assert_raises(Arca::Rejection) { Arca::PadronClient.new(credentials: production_credentials, service:).find_person(tax_id: "30123456781") }
    refute_kind_of Arca::PadronClient::NotFound, error
  end

  def test_network_failures_are_transient
    service = Object.new
    service.define_singleton_method(:get_persona) { |_| raise Arca::TransientError, "ARCA no está disponible" }

    assert_raises(Arca::TransientError) { Arca::PadronClient.new(credentials: production_credentials, service:).find_person(tax_id: "30123456781") }
  end
end
