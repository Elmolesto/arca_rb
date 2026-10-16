require "openssl"

module Arca
  # The certificate that signs every request, the CUIT that owns it and the
  # environment it was issued for. One set is shared by the WSFE and padrón
  # clients; the issuer being invoiced for may be a different CUIT that
  # delegated the service to this one.
  #
  # `cuit` is the certificate owner. ARCA writes it in the certificate subject
  # (serialNumber=CUIT 20111111112), so it is read from there unless given.
  #
  # `ticket_store` keeps WSAA access tickets, keyed by the certificate owner so
  # every issuer delegating to it shares them. See Arca::TicketStore.
  class Credentials
    def initialize(environment:, certificate_pem:, private_key_pem:, cuit: nil, ticket_store: TicketStore::File.new(File.join(Dir.pwd, "tmp", "arca")))
      @environment = Environment.fetch(environment)
      @given_cuit = cuit.nil? || cuit.to_s.strip.empty? ? nil : cuit.to_s.gsub(/\D/, "")
      @certificate_pem = certificate_pem
      @private_key_pem = private_key_pem
      @ticket_store = ticket_store
    end

    attr_reader :environment, :certificate_pem, :private_key_pem, :ticket_store

    def cuit = @given_cuit || certificate_cuit.to_s

    # The CUIT in the certificate subject, or nil if it has none or cannot be
    # read.
    def certificate_cuit
      serial = OpenSSL::X509::Certificate.new(certificate_pem).subject.to_a.find { |name, _value, _type| name == "serialNumber" }
      serial && serial[1][/\ACUIT (\d{11})\z/, 1]
    rescue OpenSSL::OpenSSLError, TypeError
      nil
    end

    # When the certificate stops working. Renewing it takes a few days of
    # paperwork in ARCA, so apps should warn well before.
    def certificate_expires_at
      OpenSSL::X509::Certificate.new(certificate_pem).not_after
    rescue OpenSSL::OpenSSLError, TypeError
      raise ConfigurationError, "No se pudo leer el certificado configurado"
    end

    def certificate_expires_within?(seconds, now: Time.now) = certificate_expires_at - now <= seconds

    def homologation? = environment == :homologation
    def production? = environment == :production

    def validate!(now: Time.now)
      raise ConfigurationError, "Falta el certificado de ARCA" if blank?(certificate_pem)
      raise ConfigurationError, "Falta la clave privada de ARCA" if blank?(private_key_pem)
      raise ConfigurationError, "Falta el CUIT dueño del certificado de ARCA" unless Identity.valid_tax_id?(cuit)
      if @given_cuit && certificate_cuit && @given_cuit != certificate_cuit
        raise ConfigurationError, "El CUIT configurado no es el del certificado de ARCA (#{certificate_cuit})"
      end

      certificate = OpenSSL::X509::Certificate.new(certificate_pem)
      private_key = OpenSSL::PKey.read(private_key_pem)
      unless private_key.private? && certificate.public_key.to_der == private_key.public_key.to_der
        raise ConfigurationError, "El certificado y la clave privada de ARCA no corresponden al mismo par"
      end
      raise ConfigurationError, "El certificado de ARCA está vencido" if certificate.not_after < now

      true
    rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
      raise ConfigurationError, "No se pudo leer el certificado o la clave privada configurados"
    end

    def inspect = "#<#{self.class.name} environment=#{environment} cuit=#{cuit}>"

    private

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
