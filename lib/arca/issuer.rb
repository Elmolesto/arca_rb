require "date"

module Arca
  # Who issues the receipts: the taxpayer as registered in ARCA. The address
  # printed on each receipt comes from the point of sale; `fiscal_address` is
  # only the fallback for points of sale without one.
  Issuer = Data.define(:cuit, :legal_name, :vat_condition, :fiscal_address, :gross_income, :activity_started_on) do
    def initialize(cuit:, legal_name:, vat_condition:, fiscal_address: nil, gross_income: nil, activity_started_on: nil)
      digits = cuit.to_s.gsub(/\D/, "")
      raise ArgumentError, "El CUIT del emisor no es válido" unless Identity.valid_tax_id?(digits)
      raise ArgumentError, "Falta la razón social del emisor" if legal_name.nil? || legal_name.to_s.strip.empty?

      super(
        cuit: digits,
        legal_name: legal_name.to_s,
        vat_condition: VatCondition.fetch(vat_condition),
        fiscal_address:,
        gross_income:,
        activity_started_on: activity_started_on.nil? || activity_started_on.is_a?(Date) ? activity_started_on : Date.iso8601(activity_started_on.to_s)
      )
    end

    # Prefills the issuer from the registry. ARCA does not report gross income
    # registration, so it has to be given.
    def self.from_padron(person, gross_income: nil)
      new(
        cuit: person.tax_id,
        legal_name: person.legal_name,
        vat_condition: person.vat_condition,
        fiscal_address: person.fiscal_address,
        activity_started_on: person.activity_started_on,
        gross_income:
      )
    end
  end
end
