module Arca
  # Taxpayer registry web service (personaServiceA5). Arca::PadronClient
  # builds on this.
  class Padron
    URLS = {
      homologation: "https://awshomo.afip.gov.ar/sr-padron/webservices/personaServiceA5",
      production: "https://aws.afip.gov.ar/sr-padron/webservices/personaServiceA5"
    }.freeze
    NAMESPACE = "http://a5.soap.ws.server.puc.sr/".freeze

    # Homologation only has the legacy service name (ws_sr_padron_a5)
    # delegated; with the current one ARCA answers "Computador no autorizado a
    # acceder al servicio". Production uses the current one.
    SERVICES = { homologation: "ws_sr_padron_a5", production: "ws_sr_constancia_inscripcion" }.freeze

    def initialize(credentials:, transport: Soap::Transport.new, wsaa: nil)
      @credentials = credentials
      @transport = transport
      @wsaa = wsaa || Wsaa.new(credentials:, service: SERVICES.fetch(credentials.environment), transport:)
    end

    def get_persona(tax_id)
      auth = @wsaa.auth
      response = Soap.call(
        @transport,
        url: URLS.fetch(@credentials.environment),
        namespace: NAMESPACE,
        operation: "getPersona",
        qualified: false,
        body: { "token" => auth.fetch(:token), "sign" => auth.fetch(:sign), "cuitRepresentada" => @credentials.cuit, "idPersona" => tax_id }
      )
      response.fetch(:persona_return)
    end
  end
end
