# Bajo nivel

Para la mayoría de los casos alcanza con el `Invoicer`. Estas piezas sirven para
lo que no cubre:

- conciliar a mano;
- emitir con importes calculados por otro sistema;
- reimprimir comprobantes históricos;
- llamar operaciones de ARCA que la gema no envuelve.

## `Arca::Client` (WSFE)

```ruby
client = Arca::Client.new(credentials:, point_of_sale: 3, issuer_cuit: "30712345671")

client.validate!                                         # configuración local, sin llamar a ARCA
client.test_connection(receipt_type: :invoice_b)         # => Connection(issuer_cuit, point_of_sale, receipt_type, last_authorized_number)
client.last_authorized_receipt(receipt_type: :invoice_b) # => 151
client.next_receipt_number(receipt_type: :invoice_b)     # => 152
client.points_of_sale                                    # => [EnabledPointOfSale(number, emission_type, blocked, removed_on)]
client.verify_point_of_sale!
client.consult_receipt(receipt_type: :invoice_b, receipt_number: 152)
# => Receipt(number, cae, expires_on, total, receiver_document_number), o nil si no existe
client.authorize(request:)                               # => Authorization(number, cae, expires_on)
```

`issuer_cuit` es, por defecto, el CUIT del certificado.

Los tipos de comprobante aceptan la clave (`:invoice_a`, `:credit_note_b`,
`:debit_note_c`, …) o el código ARCA:

| | A | B | C |
|---|---|---|---|
| Factura | 1 | 6 | 11 |
| Nota de débito | 2 | 7 | 12 |
| Nota de crédito | 3 | 8 | 13 |

## `Arca::Request`

Un comprobante tal como lo recibe WSFE. Valida las reglas fiscales al crearse
y lanza `Arca::InvalidRequest` si alguna no se cumple.

```ruby
request = Arca::Request.new(
  receipt_type: :invoice_a,
  receipt_number: 152,
  receiver: { document_type: :cuit, document_number: "30712345671", vat_condition: :responsible_registered },
  net_amount: "1000.00",
  vat_amount: "210.00",
  vat_rate: 21,
  issue_date: Date.today,
  concept: :services,                                   # :products (por defecto), :services, :products_and_services
  service_period: { from: "2026-09-01", to: "2026-09-30", payment_due: "2026-10-10" },
  associated_receipts: []                               # obligatorio en notas: [{ receipt_type:, point_of_sale:, receipt_number: }]
)
```

`Arca::Client#authorize` arma el detalle en el orden del WSDL vigente, con
`CondicionIVAReceptorId` y el desglose de IVA (`AlicIva`).

## `Arca::Wsfe`, `Arca::Padron` y `Arca::Wsaa`

Exponen las operaciones de ARCA tal cual y devuelven hashes con claves en
snake_case:

```ruby
wsfe = Arca::Wsfe.new(credentials:, cuit: "30712345671")
wsfe.last_authorized(receipt_type: 6, point_of_sale: 3)   # FECompUltimoAutorizado
wsfe.consult(receipt_type: 6, point_of_sale: 3, number: 152)  # FECompConsultar
wsfe.points_of_sale                                       # FEParamGetPtosVenta
wsfe.authorize(receipt_type: 6, point_of_sale: 3, detail: { ... })  # FECAESolicitar

Arca::Padron.new(credentials:).get_persona("30712345671") # getPersona

wsaa = Arca::Wsaa.new(credentials:, service: "wsfe")
wsaa.auth                                                 # => { token:, sign: }
```

## `Arca::Soap`

Para llamar una operación que la gema no envuelve:

```ruby
Arca::Soap.call(
  Arca::Soap::Transport.new,
  url: "https://wswhomo.afip.gov.ar/wsfev1/service.asmx",
  namespace: "http://ar.gov.afip.dif.FEV1/",
  operation: "FEParamGetTiposMonedas",
  action: "http://ar.gov.afip.dif.FEV1/FEParamGetTiposMonedas",
  body: { "Auth" => { "Token" => token, "Sign" => sign, "Cuit" => "30712345671" } }
)
```

- **Cuerpo.** Los hashes respetan el orden de las claves y los arrays repiten
  el elemento. Las `Date` se envían como `AAAAMMDD` y los `BigDecimal` con dos
  decimales.
- **Errores.** Un SOAP fault lanza `Arca::Soap::ResponseError`; una respuesta
  vacía o que no es XML, `Arca::TransientError`.

## Reglas fiscales sueltas

```ruby
Arca::ReceiptType.for(issuer_vat_condition: :responsible_registered, receiver_vat_condition: :final_consumer)  # Factura B
Arca::ReceiptType.credit_note_for(:invoice_a)        # Nota de crédito A
Arca::VatCondition.id_for(:monotributo)              # 6
Arca::VatCondition.label(:vat_exempt)                # "IVA Sujeto Exento"
Arca::VatRate.split(total: "1210", percent: 21)      # neto 1000 e IVA 210, como BigDecimal
Arca::Identity.valid_tax_id?("30-71234567-1")        # dígito verificador
Arca::Pricing.call(receipt_type:, items:, vat_rate: 21, prices_include_vat: true)
```
