require "base64"
require "openssl"
require "time"

module Arca
  # Authentication (WSAA): signs a login request with the certificate and
  # exchanges it for a token and sign, cached in the credentials' ticket store.
  class Wsaa
    URLS = {
      homologation: "https://wsaahomo.afip.gov.ar/ws/services/LoginCms",
      production: "https://wsaa.afip.gov.ar/ws/services/LoginCms"
    }.freeze
    NAMESPACE = "http://wsaa.view.sua.dvadac.desein.afip.gov".freeze
    # Renew a little before expiry so a ticket never lapses mid-request.
    RENEWAL_MARGIN = 120
    # Another process may be logging in with the same certificate right now;
    # give it a moment to store its ticket before giving up.
    STORE_RETRIES = 3

    Ticket = Data.define(:token, :sign, :expires_at) do
      def self.parse(json)
        data = JSON.parse(json)
        new(token: data.fetch("token"), sign: data.fetch("sign"), expires_at: Time.iso8601(data.fetch("expires_at")))
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError
        nil
      end

      def valid?(now) = expires_at - RENEWAL_MARGIN > now
      def to_json(*) = JSON.generate(token:, sign:, expires_at: expires_at.iso8601)
    end

    def initialize(credentials:, service:, transport: Soap::Transport.new, clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) })
      @credentials = credentials
      @service = service
      @transport = transport
      @clock = clock
      @sleeper = sleeper
    end

    def auth
      ticket = self.ticket
      { token: ticket.token, sign: ticket.sign }
    end

    def ticket
      return @ticket if @ticket&.valid?(now)

      @ticket = stored_ticket || login
    end

    private

    attr_reader :credentials, :service

    def key = "arca/wsaa/#{credentials.cuit}/#{credentials.environment}/#{service}"
    def now = @clock.call

    def stored_ticket
      ticket = credentials.ticket_store.read(key)&.then { |json| Ticket.parse(json) }
      ticket if ticket&.valid?(now)
    end

    def login
      credentials.validate!(now:)
      response = Soap.call(@transport, url: URLS.fetch(credentials.environment), namespace: NAMESPACE, operation: "loginCms", body: { "in0" => signed_request })
      ticket = parse_ticket(response.fetch(:login_cms_return))
      credentials.ticket_store.write(key, ticket.to_json, expires_in: (ticket.expires_at - now).ceil)
      ticket
    rescue Soap::ResponseError => error
      raise unless error.code?("coe.alreadyAuthenticated")

      ticket_from_another_process
    end

    # ARCA says a valid ticket already exists. If another process just got it,
    # it will show up in the store; if it was lost (an ephemeral disk, a
    # store that is not shared), nothing can be done until it expires.
    def ticket_from_another_process
      STORE_RETRIES.times do |attempt|
        @sleeper.call(attempt + 1)
        ticket = stored_ticket
        return ticket if ticket
      end

      raise TransientError, "ARCA ya entregó un ticket de acceso para #{service} que no está en el almacenamiento de tickets; " \
        "se podrá autenticar de nuevo cuando venza (hasta 12 horas). Revisá que el almacenamiento sea persistente y compartido."
    end

    def signed_request
      certificate = OpenSSL::X509::Certificate.new(credentials.certificate_pem)
      key = OpenSSL::PKey.read(credentials.private_key_pem)
      Base64.strict_encode64(OpenSSL::PKCS7.sign(certificate, key, login_ticket_request, [], OpenSSL::PKCS7::BINARY).to_der)
    end

    def login_ticket_request
      time = now
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <loginTicketRequest version="1.0">
          <header>
            <uniqueId>#{time.to_i}</uniqueId>
            <generationTime>#{(time - 600).iso8601}</generationTime>
            <expirationTime>#{(time + 600).iso8601}</expirationTime>
          </header>
          <service>#{service}</service>
        </loginTicketRequest>
      XML
    end

    def parse_ticket(xml)
      document = Nokogiri::XML(xml) { |config| config.strict.nonet }
      Ticket.new(
        token: document.at_xpath("//credentials/token").text,
        sign: document.at_xpath("//credentials/sign").text,
        expires_at: Time.iso8601(document.at_xpath("//header/expirationTime").text)
      )
    rescue Nokogiri::XML::SyntaxError, NoMethodError, ArgumentError
      raise Rejection, "ARCA respondió un ticket de acceso que no se puede leer"
    end
  end
end
