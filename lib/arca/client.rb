require "bigdecimal"
require "date"

module Arca
  # Electronic invoicing (WSFE). Authenticates with `credentials` and issues
  # receipts for `issuer_cuit`, which defaults to the certificate owner and may
  # be any CUIT that delegated WSFE to it.
  class Client
    Authorization = Data.define(:number, :cae, :expires_on)
    Receipt = Data.define(:number, :cae, :expires_on, :total, :receiver_document_number)
    Connection = Data.define(:issuer_cuit, :point_of_sale, :receipt_type, :last_authorized_number)
    EnabledPointOfSale = Data.define(:number, :emission_type, :blocked, :removed_on) do
      def blocked? = blocked
      def active? = !blocked && removed_on.nil?
    end

    # WSFE answers 602 when the queried receipt does not exist.
    RECEIPT_NOT_FOUND = 602

    def initialize(credentials:, point_of_sale:, issuer_cuit: credentials.cuit, transport: Soap::Transport.new, wsfe: nil)
      @credentials = credentials
      @issuer_cuit = issuer_cuit.to_s.gsub(/\D/, "")
      @point_of_sale = point_of_sale
      @transport = transport
      @wsfe = wsfe
    end

    attr_reader :credentials, :issuer_cuit

    def environment = credentials.environment

    def point_of_sale
      Integer(@point_of_sale).tap { |value| raise ArgumentError unless value.positive? }
    rescue ArgumentError, TypeError
      raise ConfigurationError, "El punto de venta de ARCA debe ser positivo"
    end

    # Checks everything that can fail before talking to ARCA.
    def validate!
      credentials.validate!
      raise ConfigurationError, "Falta el CUIT emisor de ARCA" unless Identity.valid_tax_id?(issuer_cuit)

      point_of_sale
      true
    end

    def test_connection(receipt_type: :invoice_c)
      Connection.new(
        issuer_cuit:,
        point_of_sale:,
        receipt_type: receipt_type_code(receipt_type),
        last_authorized_number: last_authorized_receipt(receipt_type:)
      )
    end

    def last_authorized_receipt(receipt_type:)
      wsfe.last_authorized(receipt_type: receipt_type_code(receipt_type), point_of_sale:)
    rescue Soap::ResponseError, KeyError, ArgumentError, TypeError => error
      raise rejection("ARCA rechazó la consulta de conexión", error)
    end

    def next_receipt_number(receipt_type:) = last_authorized_receipt(receipt_type:) + 1

    # Points of sale the issuer has enabled for web services in ARCA.
    def points_of_sale
      wsfe.points_of_sale.map do |entry|
        EnabledPointOfSale.new(
          number: Integer(entry.fetch(:nro)),
          emission_type: entry[:emision_tipo].to_s,
          blocked: entry[:bloqueado].to_s.upcase == "S",
          removed_on: entry[:fch_baja].to_s.match?(/\A\d{8}\z/) ? parse_date(entry[:fch_baja]) : nil
        )
      end
    rescue Soap::ResponseError => error
      return [] if error.code?(RECEIPT_NOT_FOUND)

      raise rejection("ARCA rechazó la consulta de puntos de venta", error)
    end

    # Fails unless this client's point of sale is enabled, unblocked and not
    # removed in ARCA: the setup mistake that otherwise only shows up at the
    # first authorization. Homologation registers no points of sale (it lists
    # none and accepts any number), so there it checks nothing and returns nil.
    def verify_point_of_sale!
      return if credentials.homologation?

      enabled = points_of_sale.find { |entry| entry.number == point_of_sale }
      raise ConfigurationError, "El punto de venta #{point_of_sale} no está habilitado en ARCA para facturar por web service" unless enabled
      raise ConfigurationError, "El punto de venta #{point_of_sale} está bloqueado en ARCA" if enabled.blocked?
      raise ConfigurationError, "El punto de venta #{point_of_sale} fue dado de baja en ARCA el #{enabled.removed_on.strftime("%d/%m/%Y")}" if enabled.removed_on

      enabled
    end

    # Returns nil when ARCA has no receipt with that number, which is how a
    # retry tells an authorization that never happened from one it lost.
    def consult_receipt(receipt_type:, receipt_number:)
      response = wsfe.consult(receipt_type: receipt_type_code(receipt_type), point_of_sale:, number: Integer(receipt_number))

      Receipt.new(
        number: Integer(response.fetch(:cbte_desde)),
        cae: response.fetch(:cod_autorizacion).to_s,
        expires_on: parse_date(response.fetch(:fch_vto)),
        total: BigDecimal(response.fetch(:imp_total).to_s),
        receiver_document_number: response[:doc_nro].to_s
      )
    rescue Soap::ResponseError => error
      return nil if error.code?(RECEIPT_NOT_FOUND)

      raise rejection("ARCA rechazó la consulta del comprobante", error)
    rescue KeyError, ArgumentError, TypeError, Date::Error => error
      raise rejection("ARCA rechazó la consulta del comprobante", error)
    end

    def authorize(request:)
      raise ArgumentError, "request must be an Arca::Request" unless request.is_a?(Request)

      responses = wsfe.authorize(receipt_type: request.receipt_type.code, point_of_sale:, detail: detail(request))
      raise Rejection, "ARCA devolvió una cantidad inesperada de comprobantes" unless responses.one?

      response = responses.first
      raise detail_rejection(response) unless response.fetch(:resultado) == "A"

      Authorization.new(
        number: Integer(response.fetch(:cbte_desde)),
        cae: response.fetch(:cae).to_s,
        expires_on: parse_date(response.fetch(:cae_fch_vto))
      )
    rescue Soap::ResponseError, KeyError, TypeError, Date::Error => error
      raise rejection("ARCA rechazó la autorización del comprobante", error)
    end

    private

    def wsfe
      @wsfe ||= begin
        validate!
        Wsfe.new(credentials:, cuit: issuer_cuit, transport: @transport)
      end
    end

    def receipt_type_code(receipt_type)
      ReceiptType.fetch(receipt_type).code
    rescue InvalidRequest
      raise ConfigurationError, "El tipo de comprobante ARCA no está configurado"
    end

    # One FECAEDetRequest. WSFE validates element order against its WSDL.
    def detail(request)
      detail = {
        "Concepto" => request.concept_code,
        "DocTipo" => request.receiver.document_type_code,
        "DocNro" => Integer(request.receiver.document_number),
        "CbteDesde" => request.receipt_number,
        "CbteHasta" => request.receipt_number,
        "CbteFch" => request.issue_date,
        "ImpTotal" => request.total_amount,
        "ImpTotConc" => 0,
        "ImpNeto" => request.net_amount,
        "ImpOpEx" => 0,
        "ImpTrib" => 0,
        "ImpIVA" => request.vat_amount
      }
      if request.services?
        detail["FchServDesde"] = request.service_period.from
        detail["FchServHasta"] = request.service_period.to
        detail["FchVtoPago"] = request.service_period.payment_due
      end
      detail["MonId"] = "PES"
      detail["MonCotiz"] = 1
      detail["CondicionIVAReceptorId"] = request.receiver.vat_condition_id
      if request.associated_receipts.any?
        detail["CbtesAsoc"] = {
          "CbteAsoc" => request.associated_receipts.map do |receipt|
            { "Tipo" => receipt.receipt_type, "PtoVta" => receipt.point_of_sale, "Nro" => receipt.receipt_number }
          end
        }
      end
      if request.receipt_type.vat_charged
        detail["Iva"] = { "AlicIva" => [ { "Id" => VatRate.id_for(request.vat_rate), "BaseImp" => request.net_amount, "Importe" => request.vat_amount } ] }
      end
      detail
    end

    def parse_date(value)
      return value if value.is_a?(Date)

      Date.parse(value.to_s)
    end

    def detail_rejection(response)
      entries = Soap.list(response.dig(:observaciones, :obs)) + Array(response[:errors])
      Rejection.new(
        message_with_codes("ARCA rechazó la autorización del comprobante", codes_from(entries)),
        codes: codes_from(entries),
        diagnostics: entries.filter_map { |entry| entry[:msg] }.map(&:to_s)
      )
    end

    def rejection(message, error)
      codes = error.is_a?(Soap::ResponseError) ? codes_from(error.errors) : []
      return error if error.is_a?(Error) && !error.is_a?(Soap::ResponseError)

      Rejection.new(message_with_codes(message, codes), codes:, diagnostics: [ error.message ].reject(&:empty?))
    end

    def codes_from(entries)
      Array(entries).filter_map do |entry|
        code = entry[:code].to_s
        code if code.match?(/\A\d{1,10}\z/)
      end
    end

    def message_with_codes(message, codes)
      codes.empty? ? message : "#{message} (códigos ARCA: #{codes.join(", ")})"
    end
  end
end
