require "test_helper"

class Arca::CredentialsTest < Minitest::Test
  def test_rejects_unknown_environments
    assert_raises(Arca::ConfigurationError) do
      Arca::Credentials.new(environment: :testing, cuit: "20111111112", certificate_pem: "c", private_key_pem: "k")
    end
  end

  def test_accepts_a_matching_certificate_and_key
    certificate_pem, private_key_pem = certificate_pair

    assert Arca::Credentials.new(environment: :homologation, cuit: "20-11111111-2", certificate_pem:, private_key_pem:).validate!
  end

  def test_rejects_a_certificate_from_another_key
    certificate_pem, = certificate_pair
    _, other_key_pem = certificate_pair
    credentials = Arca::Credentials.new(environment: :homologation, cuit: "20111111112", certificate_pem:, private_key_pem: other_key_pem)

    error = assert_raises(Arca::ConfigurationError) { credentials.validate! }
    assert_equal "El certificado y la clave privada de ARCA no corresponden al mismo par", error.message
  end

  def test_rejects_an_expired_certificate
    certificate_pem, private_key_pem = certificate_pair(not_after: Time.now - 60)
    credentials = Arca::Credentials.new(environment: :production, cuit: "20111111112", certificate_pem:, private_key_pem:)

    error = assert_raises(Arca::ConfigurationError) { credentials.validate! }
    assert_equal "El certificado de ARCA está vencido", error.message
  end

  def test_rejects_an_invalid_cuit
    certificate_pem, private_key_pem = certificate_pair
    credentials = Arca::Credentials.new(environment: :production, cuit: "20351770548", certificate_pem:, private_key_pem:)

    assert_raises(Arca::ConfigurationError) { credentials.validate! }
  end

  def test_reports_when_the_certificate_expires
    certificate_pem, private_key_pem = certificate_pair(not_after: Time.utc(2028, 8, 2))
    credentials = Arca::Credentials.new(environment: :production, cuit: "20111111112", certificate_pem:, private_key_pem:)

    assert_equal Time.utc(2028, 8, 2), credentials.certificate_expires_at
    assert credentials.certificate_expires_within?(30 * 86_400, now: Time.utc(2028, 7, 10))
    refute credentials.certificate_expires_within?(30 * 86_400, now: Time.utc(2028, 6, 1))
  end

  def test_does_not_leak_secrets_when_inspected
    refute_includes homologation_credentials.inspect, "key"
  end
end
