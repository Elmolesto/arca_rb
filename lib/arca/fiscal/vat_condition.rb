module Arca
  # Receiver VAT condition (CondicionIVAReceptorId), also used to describe the
  # issuer when choosing the receipt letter.
  module VatCondition
    IDS = {
      responsible_registered: 1,
      vat_exempt: 4,
      final_consumer: 5,
      monotributo: 6
    }.freeze

    # How ARCA prints each condition on receipts.
    LABELS = {
      responsible_registered: "IVA Responsable Inscripto",
      vat_exempt: "IVA Sujeto Exento",
      final_consumer: "Consumidor Final",
      monotributo: "Responsable Monotributo"
    }.freeze

    # Accepts a symbol (:monotributo) or an ARCA id (6, "6").
    def self.fetch(value)
      raise InvalidRequest, "Falta la condición frente al IVA" if value.nil? || value.to_s.strip.empty?
      return IDS.key(Integer(value)) || raise(KeyError) if value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      value.to_sym.tap { |condition| IDS.fetch(condition) }
    rescue KeyError, NoMethodError, ArgumentError, TypeError
      raise InvalidRequest, "La condición frente al IVA no está soportada"
    end

    def self.id_for(value) = IDS.fetch(fetch(value))

    # Known conditions get ARCA's wording; anything else is printed as given.
    def self.label(value)
      LABELS.fetch(fetch(value))
    rescue InvalidRequest
      value.to_s
    end

    def self.valid?(value)
      fetch(value)
      true
    rescue InvalidRequest
      false
    end
  end
end
