require "minitest/autorun"
require "openssl"
require "arca_rb"

module ArcaTestHelpers
  def homologation_credentials(cuit: "20111111112")
    Arca::Credentials.new(environment: :homologation, cuit:, certificate_pem: "certificate", private_key_pem: "key")
  end

  def production_credentials(cuit: "20111111112")
    Arca::Credentials.new(environment: :production, cuit:, certificate_pem: "certificate", private_key_pem: "key")
  end

  def certificate_pair(not_after: Time.now + 86_400)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=arca-test")
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 86_400
    certificate.not_after = not_after
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    [ certificate.to_pem, key.to_pem ]
  end
end

# Records every SOAP post and answers with queued [status, xml] responses.
class FakeTransport
  attr_reader :requests

  def initialize(*responses)
    @responses = responses
    @requests = []
  end

  def post(url, body, headers, ciphers: nil, operation: nil)
    @requests << { url:, body:, headers:, ciphers:, operation:, xml: Nokogiri::XML(body) }
    @responses.shift || raise("no response queued for #{url}")
  end

  def self.envelope(inner) = [ 200, %(<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>#{inner}</soap:Body></soap:Envelope>) ]

  def self.fault(code, message)
    [ 500, %(<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body><soapenv:Fault>) +
      %(<faultcode xmlns:ns1="http://xml.apache.org/axis/">ns1:#{code}</faultcode><faultstring>#{message}</faultstring></soapenv:Fault></soapenv:Body></soapenv:Envelope>) ]
  end
end

# A WSAA double that hands out a fixed ticket.
class FakeWsaa
  def auth = { token: "TOKEN", sign: "SIGN" }
end

Minitest::Test.include(ArcaTestHelpers)
