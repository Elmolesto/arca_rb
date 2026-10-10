require "cgi/escape"
require "date"

module Arca
  # Taxpayer registry lookup (constancia de inscripción).
  class PadronClient
    # ARCA has no usable record for the CUIT: it does not exist or has no
    # constancia de inscripción.
    NotFound = Class.new(Rejection)

    Person = Data.define(:tax_id, :legal_name, :fiscal_address, :vat_condition, :activity_started_on, :active) do
      def active? = active
    end

    # The homologation registry only knows a handful of test CUITs and answers
    # "person not found" for anything else. To exercise real flows there, every
    # lookup is swapped for the test CUIT of the same person kind.
    #
    # 20111111112 is the best-known natural-person test CUIT, but ARCA answers it
    # with errorConstancia (activities outside the F. 883 nomenclature) and no
    # name, address or VAT condition. 20221124643, from ARCA's test list, returns
    # a full record.
    HOMOLOGATION_TAX_IDS = { natural: "20221124643", legal: "30111111118" }.freeze

    # Only legal persons use these prefixes; 20, 23, 24, 25, 26 and 27 are
    # natural persons.
    LEGAL_PERSON_PREFIXES = %w[30 33 34].freeze

    NOT_FOUND_MESSAGE = "ARCA no informó datos fiscales para el CUIT consultado".freeze

    def initialize(credentials:, transport: Soap::Transport.new, service: nil)
      @credentials = credentials
      @transport = transport
      @service = service
    end

    attr_reader :credentials

    def find_person(tax_id:)
      response = service.get_persona(lookup_tax_id(tax_id))
      general_data = general_data_from(response)

      Person.new(
        tax_id: general_data.fetch(:id_persona).to_s,
        legal_name: legal_name(general_data),
        fiscal_address: fiscal_address(general_data),
        vat_condition: vat_condition(response),
        activity_started_on: activity_started_on(response),
        active: general_data.fetch(:estado_clave) == "ACTIVO"
      )
    rescue Soap::ResponseError => error
      raise NotFound.new(NOT_FOUND_MESSAGE, diagnostics: [ error.message ]) if error.message.match?(/no existe persona/i)

      raise Rejection.new("ARCA rechazó la consulta al padrón", diagnostics: [ error.message ])
    rescue KeyError, TypeError, NoMethodError => error
      raise Rejection.new("ARCA rechazó la consulta al padrón", diagnostics: [ error.message ])
    end

    private

    def service
      @service ||= begin
        credentials.validate!
        Padron.new(credentials:, transport: @transport)
      end
    end

    def lookup_tax_id(tax_id)
      digits = tax_id.to_s.gsub(/\D/, "")
      return digits unless credentials.homologation?

      HOMOLOGATION_TAX_IDS.fetch(LEGAL_PERSON_PREFIXES.include?(digits[0, 2]) ? :legal : :natural)
    end

    def general_data_from(response)
      return response.fetch(:datos_generales) if response.key?(:datos_generales)
      raise NotFound.new(NOT_FOUND_MESSAGE, diagnostics: [ response[:error_constancia].to_s ]) if response.key?(:error_constancia)

      raise Rejection, "ARCA respondió una estructura de padrón no reconocida"
    end

    def legal_name(general_data)
      name = text(general_data[:razon_social])
      name = [ general_data[:apellido], general_data[:nombre] ].map { |part| text(part) }.reject(&:empty?).join(" ") if name.empty?
      raise Rejection, "ARCA no informó una razón social" if name.empty?

      name
    end

    def fiscal_address(general_data)
      address = general_data[:domicilio_fiscal] || {}
      value = address.values_at(:direccion, :localidad, :descripcion_provincia, :cod_postal).map { |part| text(part) }.reject(&:empty?).join(", ")
      raise Rejection, "ARCA no informó un domicilio fiscal" if value.empty?

      value
    end

    def vat_condition(response)
      return :monotributo if present?(response[:datos_monotributo])

      taxes = collection(response.dig(:datos_regimen_general, :impuesto))
      return :responsible_registered if taxes.any? { |tax| tax[:id_impuesto].to_s == "30" }
      return :vat_exempt if taxes.any? { |tax| tax[:id_impuesto].to_s == "32" && tax[:estado_impuesto].to_s == "AC" }

      raise Rejection, "ARCA no informó una condición frente al IVA compatible"
    end

    def activity_started_on(response)
      started_on = parse_date(response.dig(:datos_generales, :fecha_alta))
      return started_on if started_on

      periods = [
        *collection(response.dig(:datos_regimen_general, :actividad)),
        *collection(response.dig(:datos_monotributo, :actividad_monotributista))
      ].filter_map { |activity| activity[:periodo].to_s if activity[:periodo].to_s.match?(/\A\d{6}\z/) }
      raise Rejection, "ARCA no informó el inicio de actividades" if periods.empty?

      Date.strptime(periods.min, "%Y%m")
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return unless present?(value)

      [ "%Y-%m-%d", "%Y%m%d", "%d/%m/%Y" ].each do |format|
        return Date.strptime(value.to_s[0, 10], format)
      rescue Date::Error
        next
      end

      raise Rejection, "ARCA informó una fecha de inicio de actividades no válida"
    end

    def collection(value) = value.is_a?(Array) ? value : [ value ].compact
    def text(value) = CGI.unescapeHTML(value.to_s).scrub.strip
    def present?(value) = !value.nil? && !value.to_s.strip.empty?
  end
end
