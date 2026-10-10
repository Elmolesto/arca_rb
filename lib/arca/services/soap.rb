require "bigdecimal"
require "date"
require "net/http"
require "nokogiri"
require "openssl"

module Arca
  # Minimal SOAP 1.1 over HTTPS for ARCA's services: builds document/literal
  # envelopes from ordered hashes and reads responses back into hashes with
  # snake_case symbol keys.
  module Soap
    ENVELOPE_NS = "http://schemas.xmlsoap.org/soap/envelope/".freeze

    # The service answered with an error list (WSFE <Errors>) or a SOAP fault.
    class ResponseError < Error
      def initialize(errors)
        @errors = errors.map { |error| { code: error[:code].to_s, msg: error[:msg].to_s } }.freeze
        super(@errors.map { |error| [ error[:code], error[:msg] ].reject(&:empty?).join(": ") }.join("; "))
      end

      attr_reader :errors

      def code?(code) = errors.any? { |error| error[:code] == code.to_s }
    end

    # One call to ARCA, handed to the transport's `on_request` callback. The
    # XML has tokens, signatures and login tickets filtered out, so it can go
    # to the app's logs as is.
    Event = Data.define(:operation, :url, :status, :duration, :request, :response, :error) do
      def failed? = !error.nil? || status.to_i >= 400
    end

    # Elements that carry credentials: WSFE's Token/Sign, the padrón's
    # token/sign, the signed login request and the ticket WSAA returns.
    SECRET_ELEMENTS = /<((?:\w+:)?(?:Token|Sign|token|sign|in0|loginCmsReturn))(\s[^>]*)?>.*?<\/\1>/m

    def self.filter(xml) = xml&.gsub(SECRET_ELEMENTS) { "<#{$1}#{$2}>[FILTRADO]</#{$1}>" }

    # Posts envelopes with Net::HTTP. Connection problems and server errors
    # without a SOAP body are transient.
    #
    #   Arca::Soap::Transport.new(on_request: ->(event) { logger.info("ARCA #{event.operation} #{event.status} #{event.duration.round(2)}s") })
    class Transport
      NETWORK_ERRORS = [ Timeout::Error, IOError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::ProtocolError, EOFError ].freeze

      def initialize(open_timeout: 10, read_timeout: 60, on_request: nil)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @on_request = on_request
      end

      def post(url, body, headers, ciphers: nil, operation: nil)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, response = perform(url, body, headers, ciphers:)
        [ status, response ]
      rescue TransientError => error
        raise
      ensure
        notify(operation:, url:, status:, request: body, response:, error:, started:)
      end

      private

      def perform(url, body, headers, ciphers:)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION if http.use_ssl?
        http.ciphers = ciphers if ciphers
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        response = http.post(uri.request_uri, body, headers)
        [ Integer(response.code), response.body.to_s ]
      rescue *NETWORK_ERRORS => error
        raise TransientError, "ARCA no está disponible (#{error.class})"
      end

      # A failing logger must never break an invoice.
      def notify(operation:, url:, status:, request:, response:, error:, started:)
        return unless @on_request

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        @on_request.call(Event.new(operation:, url:, status:, duration:, request: Soap.filter(request), response: Soap.filter(response), error:))
      rescue StandardError => callback_error
        warn "arca_rb: on_request falló: #{callback_error.class}: #{callback_error.message}"
      end
    end

    module_function

    # Calls `operation` and returns its response element as a hash. `namespace`
    # qualifies the operation; `qualified: false` leaves its children without
    # namespace, as services with elementFormDefault="unqualified" expect.
    def call(transport, url:, namespace:, operation:, body:, action: "", qualified: true, ciphers: nil)
      envelope = envelope(namespace:, operation:, body:, qualified:)
      status, response = transport.post(url, envelope, { "Content-Type" => "text/xml; charset=utf-8", "SOAPAction" => %("#{action}") }, ciphers:, operation:)
      document = parse(response, status)

      fault = document.at_xpath("//soap:Fault", "soap" => ENVELOPE_NS)
      raise ResponseError, [ { code: fault.at_xpath("faultcode")&.text.to_s.split(":").last, msg: fault.at_xpath("faultstring")&.text } ] if fault

      result = document.at_xpath("//soap:Body/*[1]", "soap" => ENVELOPE_NS)
      raise TransientError, "ARCA respondió sin contenido (HTTP #{status})" unless result

      to_hash(result)
    end

    def envelope(namespace:, operation:, body:, qualified:)
      element = qualified ? operation : "op:#{operation}"
      declaration = qualified ? %(xmlns="#{namespace}") : %(xmlns:op="#{namespace}")

      %(<?xml version="1.0" encoding="UTF-8"?>) +
        %(<soap:Envelope xmlns:soap="#{ENVELOPE_NS}"><soap:Body>) +
        %(<#{element} #{declaration}>#{elements(body)}</#{element}>) +
        %(</soap:Body></soap:Envelope>)
    end

    # Hash keys become elements in insertion order, which is what WSDL
    # sequences require; arrays repeat the element.
    def elements(hash)
      hash.map do |name, value|
        Array(value.is_a?(Hash) ? [ value ] : value).map do |entry|
          content = entry.is_a?(Hash) ? elements(entry) : format_value(entry).encode(xml: :text)
          "<#{name}>#{content}</#{name}>"
        end.join
      end.join
    end

    def format_value(value)
      case value
      when Date then value.strftime("%Y%m%d")
      when BigDecimal then value.round(2).to_s("F").then { |text| text.sub(/\.(\d)\z/, '.\10') }
      else value.to_s
      end
    end

    def parse(response, status)
      document = Nokogiri::XML(response) { |config| config.strict.nonet }
      raise TransientError, "ARCA respondió un documento vacío (HTTP #{status})" unless document.root

      document
    rescue Nokogiri::XML::SyntaxError
      raise TransientError, "ARCA respondió algo que no es XML (HTTP #{status})"
    end

    # Elements become snake_case symbol keys; repeated siblings become arrays;
    # leaves become strings.
    def to_hash(node)
      children = node.element_children
      return node.text if children.empty?

      children.each_with_object({}) do |child, hash|
        key = snake_case(child.name).to_sym
        value = to_hash(child)
        hash[key] = if !hash.key?(key) then value
        elsif hash[key].is_a?(Array) then hash[key] << value
        else [ hash[key], value ]
        end
      end
    end

    def snake_case(name) = name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

    # Always an array, whether the service sent zero, one or many entries.
    def list(value) = value.nil? ? [] : Array(value.is_a?(Hash) || value.is_a?(String) ? [ value ] : value)
  end
end
