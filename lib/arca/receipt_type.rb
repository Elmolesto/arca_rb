module Arca
  module ReceiptType
    ALL_RECEIVERS = VatCondition::IDS.keys.freeze

    # `vat_discriminated`: net and VAT are itemized on the document (A only).
    # `vat_charged`: the receipt carries VAT at all, so WSFE needs the AlicIva
    # breakdown (A and B). `receivers`: VAT conditions ARCA accepts for the
    # receiver of each letter (RG 5003 moved monotributistas from B to A).
    Definition = Data.define(:key, :code, :letter, :kind, :vat_discriminated, :vat_charged, :receivers) do
      def invoice? = kind == :invoice
      def credit_note? = kind == :credit_note
      def debit_note? = kind == :debit_note
      def note? = !invoice?
      def document_title = TITLES.fetch(kind)
      def accepts_receiver?(vat_condition) = receivers.include?(VatCondition.fetch(vat_condition))
    end

    TITLES = { invoice: "FACTURA", credit_note: "NOTA DE CRÉDITO", debit_note: "NOTA DE DÉBITO" }.freeze

    a_receivers = %i[responsible_registered monotributo].freeze
    b_receivers = %i[vat_exempt final_consumer].freeze

    TYPES = [
      Definition.new(key: :invoice_a, code: 1, letter: "A", kind: :invoice, vat_discriminated: true, vat_charged: true, receivers: a_receivers),
      Definition.new(key: :debit_note_a, code: 2, letter: "A", kind: :debit_note, vat_discriminated: true, vat_charged: true, receivers: a_receivers),
      Definition.new(key: :credit_note_a, code: 3, letter: "A", kind: :credit_note, vat_discriminated: true, vat_charged: true, receivers: a_receivers),
      Definition.new(key: :invoice_b, code: 6, letter: "B", kind: :invoice, vat_discriminated: false, vat_charged: true, receivers: b_receivers),
      Definition.new(key: :debit_note_b, code: 7, letter: "B", kind: :debit_note, vat_discriminated: false, vat_charged: true, receivers: b_receivers),
      Definition.new(key: :credit_note_b, code: 8, letter: "B", kind: :credit_note, vat_discriminated: false, vat_charged: true, receivers: b_receivers),
      Definition.new(key: :invoice_c, code: 11, letter: "C", kind: :invoice, vat_discriminated: false, vat_charged: false, receivers: ALL_RECEIVERS),
      Definition.new(key: :debit_note_c, code: 12, letter: "C", kind: :debit_note, vat_discriminated: false, vat_charged: false, receivers: ALL_RECEIVERS),
      Definition.new(key: :credit_note_c, code: 13, letter: "C", kind: :credit_note, vat_discriminated: false, vat_charged: false, receivers: ALL_RECEIVERS)
    ].to_h { |definition| [ definition.key, definition ] }.freeze

    C_ISSUERS = %i[monotributo vat_exempt].freeze

    # Accepts a Definition, a key (:invoice_c) or an ARCA code (11, "11").
    def self.fetch(value)
      return value if value.is_a?(Definition)
      return TYPES.values.find { |definition| definition.code == Integer(value) } || raise(KeyError) if value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      TYPES.fetch(value.to_sym)
    rescue KeyError, NoMethodError, ArgumentError, TypeError
      raise InvalidRequest, "El tipo de comprobante ARCA no está soportado"
    end

    # Picks the letter from the issuer and receiver VAT conditions and checks
    # that ARCA will accept that receiver for it.
    def self.for(issuer_vat_condition:, receiver_vat_condition:, kind: :invoice)
      issuer = vat_condition!(issuer_vat_condition, "emisor")
      receiver = vat_condition!(receiver_vat_condition, "receptor")
      letter = if C_ISSUERS.include?(issuer)
        "c"
      elsif issuer == :responsible_registered
        TYPES.fetch(:invoice_a).receivers.include?(receiver) ? "a" : "b"
      else
        raise InvalidRequest, "La condición frente al IVA del emisor no permite emitir comprobantes A, B o C"
      end

      TYPES.fetch(:"#{kind}_#{letter}") { raise InvalidRequest, "El tipo de comprobante ARCA no está soportado" }
    end

    def self.credit_note_for(receipt_type) = note_for(receipt_type, :credit_note)
    def self.debit_note_for(receipt_type) = note_for(receipt_type, :debit_note)

    # The note of `kind` with the letter of the invoice it adjusts.
    def self.note_for(receipt_type, kind)
      original = fetch(receipt_type)
      raise InvalidRequest, "Sólo se puede ajustar una factura con una nota" unless original.invoice?

      TYPES.fetch(:"#{kind}_#{original.letter.downcase}")
    end

    def self.vat_condition!(value, role)
      raise InvalidRequest, "Falta la condición frente al IVA del #{role}" if value.nil? || value.to_s.strip.empty?

      VatCondition.fetch(value)
    rescue InvalidRequest => error
      raise error if error.message.start_with?("Falta")

      raise InvalidRequest, "La condición frente al IVA del #{role} no está soportada"
    end
    private_class_method :vat_condition!
  end
end
