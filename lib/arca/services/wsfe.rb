module Arca
  # WSFEv1 operations as ARCA defines them. Arca::Client builds on this; use
  # it directly only for operations the client does not cover.
  class Wsfe
    URLS = {
      homologation: "https://wswhomo.afip.gov.ar/wsfev1/service.asmx",
      production: "https://servicios1.afip.gov.ar/wsfev1/service.asmx"
    }.freeze
    NAMESPACE = "http://ar.gov.afip.dif.FEV1/".freeze
    # The production endpoint negotiates DH parameters that OpenSSL's default
    # security level rejects. Scoped to WSFE production only.
    PRODUCTION_CIPHERS = "DEFAULT@SECLEVEL=1".freeze

    def initialize(credentials:, cuit:, transport: Soap::Transport.new, wsaa: nil)
      @credentials = credentials
      @cuit = cuit
      @transport = transport
      @wsaa = wsaa || Wsaa.new(credentials:, service: "wsfe", transport:)
    end

    def last_authorized(receipt_type:, point_of_sale:)
      Integer(request("FECompUltimoAutorizado", { "PtoVta" => point_of_sale, "CbteTipo" => receipt_type }).fetch(:cbte_nro))
    end

    # The receipt as ARCA stored it, or a ResponseError with code 602 when it
    # does not exist.
    def consult(receipt_type:, point_of_sale:, number:)
      request("FECompConsultar", { "FeCompConsReq" => { "CbteTipo" => receipt_type, "CbteNro" => number, "PtoVta" => point_of_sale } }).fetch(:result_get)
    end

    # Points of sale enabled for web services. ARCA answers 602 when there
    # are none.
    def points_of_sale
      Soap.list(request("FEParamGetPtosVenta", {}).dig(:result_get, :pto_venta))
    end

    # `detail` is one FECAEDetRequest with WSFE element names, in WSDL order.
    # Returns the FECAEDetResponse entries; header errors that came along with
    # them (a rejected receipt may carry both) are added under :errors.
    def authorize(receipt_type:, point_of_sale:, detail:)
      result = request("FECAESolicitar", {
        "FeCAEReq" => {
          "FeCabReq" => { "CantReg" => 1, "PtoVta" => point_of_sale, "CbteTipo" => receipt_type },
          "FeDetReq" => { "FECAEDetRequest" => detail }
        }
      }, errors_are_fatal: false)

      details = Soap.list(result.dig(:fe_det_resp, :fecae_det_response))
      raise Soap::ResponseError, errors(result) if details.empty? && result[:errors]

      details.map { |detail| detail.merge(errors: errors(result)) }
    end

    private

    def request(operation, body, errors_are_fatal: true)
      response = Soap.call(
        @transport,
        url: URLS.fetch(@credentials.environment),
        namespace: NAMESPACE,
        operation:,
        action: "#{NAMESPACE}#{operation}",
        body: { "Auth" => { "Token" => auth.fetch(:token), "Sign" => auth.fetch(:sign), "Cuit" => @cuit } }.merge(body),
        ciphers: @credentials.production? ? PRODUCTION_CIPHERS : nil
      )
      result = response.fetch(:"#{Soap.snake_case(operation)}_result")
      raise Soap::ResponseError, errors(result) if errors_are_fatal && result[:errors]

      result
    end

    def auth = @wsaa.auth
    def errors(result) = Soap.list(result.dig(:errors, :err)).map { |error| { code: error[:code], msg: error[:msg] } }
  end
end
