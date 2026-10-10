require "test_helper"

class Arca::SoapTest < Minitest::Test
  def test_qualifies_every_element_under_the_operation_namespace
    xml = Nokogiri::XML(Arca::Soap.envelope(namespace: "urn:x", operation: "Op", body: { "Auth" => { "Token" => "t" }, "Item" => [ { "Id" => 1 }, { "Id" => 2 } ] }, qualified: true))

    assert_equal [ "1", "2" ], xml.xpath("//x:Op/x:Item/x:Id", "x" => "urn:x").map(&:text)
    assert_equal "t", xml.at_xpath("//x:Op/x:Auth/x:Token", "x" => "urn:x").text
  end

  def test_leaves_children_unqualified_when_asked
    xml = Nokogiri::XML(Arca::Soap.envelope(namespace: "urn:x", operation: "getPersona", body: { "token" => "t" }, qualified: false))

    assert xml.at_xpath("//x:getPersona/token", "x" => "urn:x")
  end

  def test_formats_dates_and_amounts_as_arca_expects
    assert_equal "20260925", Arca::Soap.format_value(Date.new(2026, 9, 25))
    assert_equal "121.00", Arca::Soap.format_value(BigDecimal("121"))
    assert_equal "10.50", Arca::Soap.format_value(BigDecimal("10.5"))
    assert_equal "2479.35", Arca::Soap.format_value(BigDecimal("2479.349"))
  end

  def test_reads_responses_as_snake_case_hashes_with_arrays_for_repeats
    transport = FakeTransport.new(FakeTransport.envelope("<OpResponse><OpResult><CbteNro>7</CbteNro><Errors><Err><Code>1</Code></Err><Err><Code>2</Code></Err></Errors></OpResult></OpResponse>"))

    result = Arca::Soap.call(transport, url: "https://x", namespace: "urn:x", operation: "Op", body: {})

    assert_equal({ op_result: { cbte_nro: "7", errors: { err: [ { code: "1" }, { code: "2" } ] } } }, result)
    assert_equal({ "Content-Type" => "text/xml; charset=utf-8", "SOAPAction" => %("") }, transport.requests.first[:headers])
  end

  def test_turns_faults_into_response_errors
    transport = FakeTransport.new(FakeTransport.fault("cms.cert.expired", "Certificado expirado"))

    error = assert_raises(Arca::Soap::ResponseError) { Arca::Soap.call(transport, url: "https://x", namespace: "urn:x", operation: "Op", body: {}) }
    assert error.code?("cms.cert.expired")
  end

  def test_treats_non_xml_answers_as_transient
    transport = FakeTransport.new([ 502, "<html>Bad Gateway" ])

    assert_raises(Arca::TransientError) { Arca::Soap.call(transport, url: "https://x", namespace: "urn:x", operation: "Op", body: {}) }
  end

  def test_reports_each_call_with_credentials_filtered
    events = []
    transport = Arca::Soap::Transport.new(open_timeout: 1, read_timeout: 1, on_request: ->(event) { events << event })
    body = Arca::Soap.envelope(namespace: "urn:x", operation: "Op", body: { "Auth" => { "Token" => "secreto", "Sign" => "firma" }, "PtoVta" => 3 }, qualified: true)

    assert_raises(Arca::TransientError) { transport.post("https://127.0.0.1:1/", body, {}, operation: "Op") }

    assert_equal 1, events.size
    event = events.first
    assert_equal "Op", event.operation
    assert_kind_of Arca::TransientError, event.error
    assert_predicate event, :failed?
    assert_includes event.request, "<Token>[FILTRADO]</Token>"
    assert_includes event.request, "<PtoVta>3</PtoVta>"
    refute_includes event.request, "secreto"
  end

  def test_filters_login_tickets_from_responses
    filtered = Arca::Soap.filter(%(<loginCmsResponse xmlns="x"><loginCmsReturn>&lt;token&gt;abc&lt;/token&gt;</loginCmsReturn></loginCmsResponse><ns:in0>cms</ns:in0>))

    assert_equal %(<loginCmsResponse xmlns="x"><loginCmsReturn>[FILTRADO]</loginCmsReturn></loginCmsResponse><ns:in0>[FILTRADO]</ns:in0>), filtered
  end

  def test_a_failing_callback_never_breaks_the_call
    transport = Arca::Soap::Transport.new(open_timeout: 1, read_timeout: 1, on_request: ->(_) { raise "logger roto" })

    _, stderr = capture_io { assert_raises(Arca::TransientError) { transport.post("https://127.0.0.1:1/", "<x/>", {}) } }
    assert_includes stderr, "logger roto"
  end

  def test_the_real_transport_reports_network_failures_as_transient
    transport = Arca::Soap::Transport.new(open_timeout: 1, read_timeout: 1)

    assert_raises(Arca::TransientError) { transport.post("https://127.0.0.1:1/", "", {}) }
  end
end
