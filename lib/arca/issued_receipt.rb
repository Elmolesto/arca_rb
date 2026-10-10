module Arca
  # A receipt ARCA authorized. `recovered?` is true when the authorization was
  # found on retry instead of granted by this call: the receipt already existed
  # and the app had not recorded it.
  class IssuedReceipt
    attr_reader :draft, :authorization

    def self.from_h(hash)
      data = Serialization.symbolize(hash)
      authorization = Client::Authorization.new(number: Integer(data.fetch(:receipt_number)), cae: data.fetch(:cae).to_s, expires_on: Date.iso8601(data.fetch(:cae_expires_on).to_s))

      new(draft: Draft.from_h(hash), authorization:)
    end

    def initialize(draft:, authorization:, recovered: false)
      @draft = draft
      @authorization = authorization
      @recovered = recovered
    end

    def recovered? = @recovered
    def receipt_type = draft.receipt_type
    def point_of_sale = draft.point_of_sale
    def number = authorization.number
    def cae = authorization.cae
    def cae_expires_on = authorization.expires_on
    def total_amount = draft.total_amount

    def document = draft.document(authorization)
    def pdf(**options) = Pdf.render(document, **options)
    def qr = document.qr

    def to_h = draft.to_h.merge(Serialization.dump(cae:, cae_expires_on:))
  end
end
