# PDF

El PDF sigue el modelo impreso de ARCA:

- banner de copia;
- emisor, con el domicilio comercial del punto de venta;
- letra y código del comprobante;
- receptor;
- período facturado;
- comprobantes asociados;
- ítems, con las columnas de cada letra;
- totales;
- QR y CAE.

Si hay muchos ítems, pagina y deja los totales en la última hoja.

```ruby
receipt.pdf                                                  # String binario
receipt.pdf(copies: %i[original duplicate], logo: "logo.png")
File.binwrite("factura.pdf", receipt.pdf)
```

En Rails, para descargarlo:

```ruby
send_data receipt.pdf, filename: "factura-00003-00000152.pdf", type: "application/pdf", disposition: "inline"
```

## Opciones

| Opción | Por defecto | |
|---|---|---|
| `copies:` | `[:original]` | `:original`, `:duplicate`, `:triplicate`, `:quadruplicate`; un juego de hojas por copia |
| `logo:` | `nil` | Ruta o IO de una imagen; reemplaza la razón social en la cabecera |
| `fonts:` | Noto Sans | `{ normal:, bold:, italic: }` con rutas a archivos TTF |
| `proforma:` | `nil` | Ver [Proformas](#proformas) |

Las fuentes Noto Sans vienen con la gema (licencia OFL) y cubren los acentos y
la ñ.

## Qué imprime cada letra

- **A:**
  - precio unitario neto, alícuota y subtotal sin IVA por renglón;
  - neto gravado y el IVA de cada alícuota.
- **B:**
  - precios finales, con el IVA incluido;
  - a un consumidor final, el cuadro del Régimen de Transparencia Fiscal al
    Consumidor (Ley 27.743) con el IVA contenido; a un exento, no.
- **C:** precios finales, sin IVA.

En todos los casos, el total en letras.

## Borradores

Un borrador todavía no tiene CAE. Sale con el banner *BORRADOR · SIN VALIDEZ
FISCAL*, sin número, sin QR y sin CAE. Sirve para mostrar el comprobante antes
de emitirlo.

```ruby
draft = invoicer.prepare(...)
draft.pdf
```

## Proformas

Una proforma es un documento comercial de la app, como una orden de compra o
una cotización, con el mismo diseño que la factura que se va a emitir.

```ruby
draft.pdf(proforma: { title: "Orden de compra", number: 1234 })
```

- Sale con letra X, la leyenda *NO FISCAL*, el título y el número de la app.
- No muestra punto de venta, CAE ni QR.
- Un comprobante autorizado no se puede imprimir como proforma.

Para una proforma no hace falta reservar número en ARCA. Armá el documento
directamente, como en la sección siguiente.

## Comprobantes que no pasan por el `Invoicer`

`Arca::Pdf::Document` tiene todo lo que se imprime. Sirve para comprobantes
históricos, emitidos por otro sistema o proformas:

```ruby
receipt_type = Arca::ReceiptType.for(issuer_vat_condition: issuer.vat_condition, receiver_vat_condition: :responsible_registered)
pricing = Arca::Pricing.call(receipt_type:, items:, vat_rate: 21, prices_include_vat: true)

document = Arca::Pdf::Document.new(
  receipt_type:,
  issued_on: Date.today,
  issuer:,
  commercial_address: "Rivadavia 100, Moreno",   # opcional
  receiver: { legal_name: "Cliente S.A.", document_type: :cuit, document_number: "30712345671", vat_condition: :responsible_registered },
  items: pricing.items,
  net_amount: pricing.net_amount,
  vat_amount: pricing.vat_amount,
  # para un comprobante autorizado:
  point_of_sale: 3, receipt_number: 152, cae: "86410977999643", cae_expires_on: Date.new(2026, 10, 19)
)

Arca::Pdf.render(document, copies: %i[original duplicate])
Arca::Pdf.render(document_sin_cae, proforma: { title: "Cotización", number: "Q-88" })
```

`Arca::Pricing.call` calcula el neto y el IVA a partir de los ítems y los
precios que imprime cada letra, igual que el `Invoicer`.

Otros parámetros opcionales de `Document`:
- `service_period:`, `payment_condition:`, `associated_receipts:` y
  `observations:`;
- `exempt_amount:`, `untaxed_amount:` y `other_taxes_amount:`;
- `currency:` (`"PES"` o `"DOL"`) y `exchange_rate:`.

## QR

```ruby
receipt.qr.url    # https://www.arca.gob.ar/fe/qr/?p=...
receipt.qr.png    # StringIO con la imagen
```

El QR sigue la especificación de la RG 4892 y lleva los datos del comprobante
autorizado.
