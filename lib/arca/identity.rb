module Arca
  # Receiver identification as WSFE expects it (DocTipo / DocNro).
  module Identity
    DOCUMENT_TYPES = { cuit: 80, cuil: 86, dni: 96, unidentified: 99 }.freeze
    CHECK_DIGIT_WEIGHTS = [ 5, 4, 3, 2, 7, 6, 5, 4, 3, 2 ].freeze

    # Accepts a symbol (:cuit) or an ARCA code (80, "80").
    def self.document_type(value)
      return DOCUMENT_TYPES.key(Integer(value)) || raise(KeyError) if value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      value.to_sym.tap { |type| DOCUMENT_TYPES.fetch(type) }
    rescue KeyError, NoMethodError, ArgumentError, TypeError
      raise InvalidRequest, "El tipo de documento ARCA no está soportado"
    end

    def self.code_for(value) = DOCUMENT_TYPES.fetch(document_type(value))

    def self.normalize(document_type:, document_number:)
      type = document_type(document_type)
      return { type:, number: "0" } if type == :unidentified

      { type:, number: document_number.to_s.gsub(/\D/, "") }
    end

    def self.valid?(document_type:, document_number:)
      identity = normalize(document_type:, document_number:)

      case identity.fetch(:type)
      when :unidentified then true
      when :dni then identity.fetch(:number).match?(/\A\d{7,8}\z/)
      else valid_tax_id?(identity.fetch(:number))
      end
    rescue InvalidRequest
      false
    end

    # CUIT and CUIL share the modulo 11 check digit. Separators are ignored.
    def self.valid_tax_id?(value)
      digits = value.to_s.gsub(/[\s.-]/, "")
      return false unless digits.match?(/\A\d{11}\z/)

      remainder = digits[0, 10].chars.zip(CHECK_DIGIT_WEIGHTS).sum { |digit, weight| digit.to_i * weight } % 11
      expected = { 0 => 0, 1 => 9 }.fetch(remainder, 11 - remainder)
      digits[-1].to_i == expected
    end
  end
end
