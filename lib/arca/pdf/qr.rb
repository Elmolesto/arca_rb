require "base64"
require "bigdecimal"
require "cgi/escape"
require "date"
require "json"
require "rqrcode"
require "stringio"

module Arca
  # The QR code ARCA requires on every authorized receipt (RG 4892).
  class Qr
    BASE_URL = "https://www.arca.gob.ar/fe/qr/".freeze

    def initialize(issued_on:, issuer_cuit:, point_of_sale:, receipt_type:, receipt_number:, total:, cae:, receiver_document_type: nil, receiver_document_number: nil, currency: "PES", exchange_rate: 1)
      @issued_on = issued_on.is_a?(Date) ? issued_on : Date.iso8601(issued_on.to_s)
      @issuer_cuit = Integer(issuer_cuit.to_s.gsub(/\D/, ""))
      @point_of_sale = Integer(point_of_sale)
      @receipt_type = ReceiptType.fetch(receipt_type).code
      @receipt_number = Integer(receipt_number)
      @total = BigDecimal(total.to_s)
      @cae = Integer(cae)
      @receiver_document_type = receiver_document_type.nil? ? nil : Identity.code_for(receiver_document_type)
      @receiver_document_number = blank?(receiver_document_number) ? nil : Integer(receiver_document_number.to_s.gsub(/\D/, ""))
      @currency = currency
      @exchange_rate = exchange_rate
    end

    def payload
      {
        ver: 1,
        fecha: @issued_on.iso8601,
        cuit: @issuer_cuit,
        ptoVta: @point_of_sale,
        tipoCmp: @receipt_type,
        nroCmp: @receipt_number,
        importe: @total.to_f,
        moneda: @currency,
        ctz: Float(@exchange_rate),
        tipoDocRec: @receiver_document_type,
        nroDocRec: @receiver_document_number,
        tipoCodAut: "E",
        codAut: @cae
      }.compact
    end

    def url = "#{BASE_URL}?p=#{CGI.escape(Base64.strict_encode64(JSON.generate(payload)))}"

    def png(size: 240) = StringIO.new(RQRCode::QRCode.new(url, level: :m).as_png(size:).to_s)

    private

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
