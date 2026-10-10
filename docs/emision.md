# Emitir comprobantes

`Arca::Invoicer` emite para un emisor en un punto de venta. Con los datos de la
venta, el `Invoicer`:

- elige la letra;
- calcula el neto y el IVA;
- reserva el número;
- pide el CAE;
- arma el PDF.

```ruby
invoicer = Arca::Invoicer.new(credentials:, issuer:, point_of_sale:)
```

`issuer` y `point_of_sale` aceptan los objetos (`Arca::Issuer`,
`Arca::PointOfSale`) o un hash con sus atributos. Ver
[Configuración](configuracion.md).

## Los dos pasos

```ruby
draft = invoicer.prepare(receiver:, items:, issue_date: Date.today)   # reserva el número
sale.update!(arca: draft.to_h)                                        # guardalo ANTES de autorizar

receipt = invoicer.authorize(draft)                                   # pide el CAE
sale.update!(arca: receipt.to_h, cae: receipt.cae)
```

La separación existe por un problema concreto: ARCA puede autorizar el
comprobante y la respuesta perderse (timeout, el proceso se reinicia). Si la
app no guardó qué número había pedido, al reintentar pide el siguiente y emite
**dos** comprobantes por la misma venta.

Con el borrador guardado, el reintento manda el mismo número. ARCA contesta que
ese número ya no es el siguiente (código 10016); la gema consulta el
comprobante y, si tiene el mismo receptor y el mismo total, devuelve esa
autorización con `receipt.recovered? == true` en lugar de emitir otra.

```ruby
draft = Arca::Draft.from_h(sale.arca)    # el JSON guardado
receipt = invoicer.authorize(draft)      # seguro de reintentar
```

`to_h` devuelve un hash de tipos JSON (strings, números y fechas ISO 8601), listo
para una columna `json`/`jsonb` o un archivo. Incluye todo lo que el PDF
imprime, así que el comprobante se puede reimprimir sin volver a consultar tus
modelos.

### Si otro comprobante usó el número

Si el número reservado lo tomó otro comprobante (por ejemplo, alguien facturó
a mano desde el sitio de ARCA), `authorize` lanza `Arca::ReceiptNumberTaken`.
Ese número nunca fue tuyo: descartá el borrador y llamá a `prepare` de nuevo.

### Si ARCA rechaza

Si ARCA rechaza el comprobante, `authorize` lanza `Arca::Rejection` con los
códigos en `error.codes`. Un rechazo no consume el número, pero el borrador
tiene la fecha de emisión fija. Para volver a intentar otro día:

1. Confirmá que ARCA no tiene ese número con
   `invoicer.client.consult_receipt(receipt_type: draft.receipt_type, receipt_number: draft.receipt_number)`.
   Si devuelve `nil`, no lo tiene.
2. Descartá el borrador.
3. Llamá a `prepare` de nuevo.

### Concurrencia

ARCA numera por punto de venta y tipo de comprobante. Si dos procesos preparan
a la vez para el mismo punto de venta, los dos reservan el mismo número. Evitarlo
le toca a la app: un lock por punto de venta o un único worker de facturación.
En [Integración con Rails](rails.md) hay un ejemplo con `limits_concurrency`.

## Receptor

```ruby
receiver = {
  document_type: :cuit,                     # :cuit, :cuil, :dni, :unidentified (o el código ARCA: 80, 86, 96, 99)
  document_number: "30-71234567-1",         # se ignoran guiones y puntos
  vat_condition: :responsible_registered,   # :monotributo, :vat_exempt, :final_consumer (o el id ARCA)
  legal_name: "Cliente S.A.",               # opcional, para el PDF
  fiscal_address: "Mitre 50, Rosario"       # opcional, para el PDF
}
```

Para un consumidor final sin identificar:

```ruby
{ document_type: :unidentified, document_number: 0, vat_condition: :final_consumer }
```

ARCA exige identificar al consumidor final cuando el total supera un monto que
actualiza periódicamente. La gema no controla ese tope: si se supera, ARCA
rechaza el comprobante.

## Letra

Sale de la condición frente al IVA del emisor y del receptor:

| Emisor | Receptor | Letra |
|---|---|---|
| Responsable inscripto | Responsable inscripto o monotributista | A |
| Responsable inscripto | Exento o consumidor final | B |
| Monotributista o exento | Cualquiera | C |

La factura A a monotributistas rige desde la RG 5003. `CondicionIVAReceptorId`
se informa siempre, como exige ARCA.

## Ítems e importes

```ruby
items = [
  { description: "Abono mensual", quantity: 1, unit_price: 12_100 },
  { description: "Horas extra", quantity: 3, unit_price: 6_050, unit: "horas", code: "HX" },
  { description: "Instalación", unit_price: 24_200, discount_percent: 10 },
  { description: "Insumos", unit_price: 1_210, discount_amount: 100 }
]
```

| Campo | Por defecto | |
|---|---|---|
| `description` | — | Obligatorio |
| `unit_price` | — | Obligatorio; acepta Integer, String o BigDecimal (no uses Float) |
| `quantity` | `1` | |
| `unit` | `"unidades"` | Se imprime en A y B |
| `code` | `nil` | Columna *Código* |
| `discount_percent` / `discount_amount` | `0` | Bonificación del renglón |

- **Precios con IVA.** Por defecto `unit_price` incluye IVA, que es como se
  vende en general. El neto y el IVA salen del total
  (`prices_include_vat: true`).
- **Precios netos.** Con `prices_include_vat: false`, `unit_price` es neto y se
  le suma el IVA.
- **Lo que imprime cada letra.** Las A imprimen precios netos con la alícuota;
  las B y C, precios finales.
- **Redondeo.** Cuando hay que convertir, la diferencia de centavos se ajusta
  en el último renglón para que las filas sumen exactamente lo autorizado.

```ruby
invoicer.prepare(receiver:, items:, issue_date:, vat_rate: "10.5", prices_include_vat: false)
```

`vat_rate` acepta 0, 2.5, 5, 10.5, 21 (por defecto) y 27. Hay una sola alícuota
por comprobante. En las C no aplica, porque no llevan IVA.

## Productos y servicios

Por defecto el comprobante es de concepto 1 (productos). Con un período
facturado pasa a concepto 2 (servicios), y ARCA recibe las fechas de servicio y
el vencimiento del pago:

```ruby
invoicer.prepare(
  receiver:, items:, issue_date: Date.new(2026, 10, 1),
  service_period: { from: Date.new(2026, 9, 1), to: Date.new(2026, 9, 30), payment_due: Date.new(2026, 10, 10) }
)
```

- `concept: :products_and_services` emite concepto 3.
- `concept: :products` con un período lo imprime sin informarlo a ARCA.
- `payment_due` no puede ser anterior a la fecha de emisión.

ARCA acepta fechas de emisión hasta 5 días antes o después del día de hoy en
productos, y hasta 10 en servicios.

## Otras opciones de `prepare`

| Opción | Por defecto | |
|---|---|---|
| `payment_condition:` | `"Contado"` | Se imprime como *Condición de venta* |
| `observations:` | `nil` | Texto libre al pie de los ítems |
| `receipt_number:` | el siguiente en ARCA | Forzar un número (no lo consulta) |

## Notas de crédito y débito

Las notas toman de la factura:
- la letra;
- el receptor;
- el concepto y el período;
- la condición de venta.

Además, la asocian (`CbtesAsoc`), como exige ARCA.

```ruby
invoice = Arca::IssuedReceipt.from_h(sale.arca)

total = invoicer.prepare_credit_note(invoice, issue_date: Date.today)
partial = invoicer.prepare_credit_note(invoice, issue_date: Date.today,
  items: [ { description: "Devolución parcial", unit_price: 5_000 } ])
late_fee = invoicer.prepare_debit_note(invoice, issue_date: Date.today,
  items: [ { description: "Recargo por mora", unit_price: 1_210 } ])

credit_note = invoicer.authorize(total)    # mismo flujo de dos pasos
```

- Sin `items`, la nota de crédito acredita la factura completa.
- Una nota de crédito no puede superar el total de la factura. Descontar notas
  anteriores le toca a la app.
- Una nota de crédito puede asociar una factura o una nota de débito.
- En servicios, el vencimiento del pago de la nota se corre a su fecha de
  emisión si el de la factura ya pasó.

## El comprobante emitido

```ruby
receipt.number            # 152
receipt.cae               # "86410977999643"
receipt.cae_expires_on    # Date
receipt.receipt_type      # Arca::ReceiptType::Definition: code 1, letter "A", kind :invoice
receipt.point_of_sale     # Arca::PointOfSale
receipt.total_amount      # BigDecimal
receipt.recovered?        # true si se recuperó en un reintento
receipt.pdf               # String binario
receipt.qr                # Arca::Qr (url, png)
receipt.to_h / Arca::IssuedReceipt.from_h(hash)
```

## Ver también

- [PDF](pdf.md) para las opciones de impresión.
- [Errores](errores.md) para qué reintentar.
- [Bajo nivel](bajo-nivel.md) para emitir sin el `Invoicer`.
