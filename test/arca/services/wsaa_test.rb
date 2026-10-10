require "test_helper"
require "tmpdir"

class Arca::WsaaTest < Minitest::Test
  NOW = Time.utc(2026, 9, 26, 15, 0, 0)

  def setup
    @certificate_pem, @private_key_pem = certificate_pair
    @store = Arca::TicketStore::Memory.new
  end

  def test_logs_in_with_a_signed_request_and_stores_the_ticket
    transport = FakeTransport.new(login_response(expires_at: NOW + 43_200))

    assert_equal({ token: "TOKEN-1", sign: "SIGN-1" }, wsaa(transport).auth)

    request = transport.requests.first
    assert_equal "https://wsaahomo.afip.gov.ar/ws/services/LoginCms", request[:url]
    cms = OpenSSL::PKCS7.new(Base64.decode64(request[:xml].at_xpath("//w:in0", "w" => Arca::Wsaa::NAMESPACE).text))
    assert cms.verify([ OpenSSL::X509::Certificate.new(@certificate_pem) ], OpenSSL::X509::Store.new, nil, OpenSSL::PKCS7::NOVERIFY)
    assert_equal "wsfe", Nokogiri::XML(cms.data).at_xpath("//service").text
    assert_equal NOW + 43_200, Arca::Wsaa::Ticket.parse(@store.read("arca/wsaa/20111111112/homologation/wsfe")).expires_at
  end

  def test_reuses_a_stored_ticket_without_calling_arca
    @store.write("arca/wsaa/20111111112/homologation/wsfe", ticket(expires_at: NOW + 3_600).to_json, expires_in: 3_600)
    transport = FakeTransport.new

    assert_equal({ token: "STORED", sign: "STORED-SIGN" }, wsaa(transport).auth)
    assert_empty transport.requests
  end

  def test_renews_a_ticket_about_to_expire
    @store.write("arca/wsaa/20111111112/homologation/wsfe", ticket(expires_at: NOW + 60).to_json, expires_in: 60)
    transport = FakeTransport.new(login_response(expires_at: NOW + 43_200))

    assert_equal "TOKEN-1", wsaa(transport).auth.fetch(:token)
  end

  def test_picks_up_the_ticket_another_process_just_obtained
    transport = FakeTransport.new(FakeTransport.fault("coe.alreadyAuthenticated", "El CEE ya posee un TA valido para el acceso al WSN solicitado"))
    other_process = ->(_seconds) { @store.write("arca/wsaa/20111111112/homologation/wsfe", ticket(expires_at: NOW + 3_600).to_json, expires_in: 3_600) }

    assert_equal "STORED", wsaa(transport, sleeper: other_process).auth.fetch(:token)
  end

  def test_explains_a_lost_ticket
    transport = FakeTransport.new(FakeTransport.fault("coe.alreadyAuthenticated", "El CEE ya posee un TA valido para el acceso al WSN solicitado"))
    waits = []

    error = assert_raises(Arca::TransientError) { wsaa(transport, sleeper: ->(seconds) { waits << seconds }).auth }
    assert_includes error.message, "persistente y compartido"
    assert_equal [ 1, 2, 3 ], waits
  end

  def test_other_faults_are_rejections
    transport = FakeTransport.new(FakeTransport.fault("cms.cert.untrusted", "Certificado no emitido por AC de confianza"))

    assert_raises(Arca::Soap::ResponseError) { wsaa(transport).auth }
  end

  def test_production_uses_the_production_endpoint_and_its_own_ticket
    transport = FakeTransport.new(login_response(expires_at: NOW + 43_200))
    credentials = Arca::Credentials.new(environment: :production, cuit: "20111111112", certificate_pem: @certificate_pem, private_key_pem: @private_key_pem, ticket_store: @store)

    Arca::Wsaa.new(credentials:, service: "wsfe", transport:, clock: -> { NOW }).auth

    assert_equal "https://wsaa.afip.gov.ar/ws/services/LoginCms", transport.requests.first[:url]
    assert @store.read("arca/wsaa/20111111112/production/wsfe")
  end

  def test_tickets_survive_in_a_file_store
    Dir.mktmpdir do |directory|
      store = Arca::TicketStore::File.new(directory)
      store.write("arca/wsaa/20111111112/homologation/wsfe", "{}", expires_in: 10)

      assert_equal "{}", Arca::TicketStore::File.new(directory).read("arca/wsaa/20111111112/homologation/wsfe")
    end
  end

  private

  def wsaa(transport, sleeper: ->(_) { })
    credentials = Arca::Credentials.new(environment: :homologation, cuit: "20111111112", certificate_pem: @certificate_pem, private_key_pem: @private_key_pem, ticket_store: @store)
    Arca::Wsaa.new(credentials:, service: "wsfe", transport:, clock: -> { NOW }, sleeper:)
  end

  def ticket(expires_at:) = Arca::Wsaa::Ticket.new(token: "STORED", sign: "STORED-SIGN", expires_at:)

  def login_response(expires_at:)
    ticket = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <loginTicketResponse version="1.0">
        <header><source>CN=wsaahomo</source><destination>SERIALNUMBER=CUIT 20111111112</destination><uniqueId>1</uniqueId>
          <generationTime>#{NOW.iso8601}</generationTime><expirationTime>#{expires_at.iso8601}</expirationTime></header>
        <credentials><token>TOKEN-1</token><sign>SIGN-1</sign></credentials>
      </loginTicketResponse>
    XML
    FakeTransport.envelope(%(<loginCmsResponse xmlns="#{Arca::Wsaa::NAMESPACE}"><loginCmsReturn>#{ticket.encode(xml: :text)}</loginCmsReturn></loginCmsResponse>))
  end
end
