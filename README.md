# arca_rb

Facturación electrónica de ARCA (ex AFIP) para Ruby: autenticación WSAA,
comprobantes por WSFEv1, consulta al padrón A5 y PDF con el QR oficial.

```ruby
draft   = invoicer.prepare(receiver: cliente, items: [ { description: "Abono mensual", unit_price: 12_100 } ], issue_date: Date.today)
receipt = invoicer.authorize(draft)
receipt.cae                           # => "86410977999643"
File.binwrite("factura.pdf", receipt.pdf)
```

- **Sin Rails ni Savon.** Habla SOAP con Net::HTTP y Nokogiri. Funciona en
  cualquier app Ruby y no carga ActiveSupport.
- **Reglas fiscales incluidas:**
  - letra A, B o C según la condición frente al IVA del emisor y del receptor;
  - `CondicionIVAReceptorId`;
  - alícuotas;
  - conceptos de productos y servicios;
  - notas de crédito y de débito asociadas.
- **Emisión a prueba de reintentos.** El número se reserva antes de llamar a
  ARCA. Si la respuesta se pierde, el reintento recupera el comprobante ya
  autorizado en lugar de emitir otro.
- **PDF con el modelo de ARCA.** Incluye original y duplicado, QR (RG 4892),
  domicilio comercial por punto de venta, el cuadro de la Ley 27.743,
  borradores y proformas.
- **Tickets de WSAA compartidos** entre procesos y servidores. Sirve para
  Heroku, Kamal o varios workers.
- **Probada contra ARCA real.** `bin/smoke` recorre todo en homologación.

> arca_rb no es un producto oficial de ARCA. Revisá con tu contador qué
> comprobantes tenés que emitir.

## Instalación

Requiere Ruby 3.3 o superior.

```ruby
# Gemfile
gem "arca_rb", github: "Elmolesto/arca_rb", tag: "v0.5.0"
```

```ruby
require "arca_rb"
```

## Uso rápido

Necesitás un certificado de ARCA con los servicios `wsfe` (y el del padrón, si
lo vas a consultar) asociados, y un punto de venta habilitado para web
services. [Configuración](docs/configuracion.md) explica cómo obtenerlos.

```ruby
credentials = Arca::Credentials.new(
  environment: :homologation,                        # :production para comprobantes reales
  certificate_pem: File.read("arca.crt"),            # el CUIT del dueño sale del certificado
  private_key_pem: File.read("arca.key")
)

issuer = Arca::Issuer.new(
  cuit: "20111111112",
  legal_name: "María González",
  vat_condition: :monotributo,
  fiscal_address: "Av. Corrientes 1234, CABA",
  activity_started_on: "2019-04-01"
)

invoicer = Arca::Invoicer.new(credentials:, issuer:, point_of_sale: { number: 3 })

# 1. Prepara el comprobante y reserva el número. Guardá draft.to_h antes de seguir.
draft = invoicer.prepare(
  receiver: { document_type: :cuit, document_number: "30-71234567-1", vat_condition: :responsible_registered,
              legal_name: "Cliente S.A.", fiscal_address: "Mitre 50, Rosario" },
  items: [ { description: "Abono mensual", quantity: 1, unit_price: 12_100 } ],
  issue_date: Date.today
)

# 2. Pide el CAE. Se puede reintentar con el mismo borrador.
receipt = invoicer.authorize(draft)
receipt.number          # => 152
receipt.cae             # => "86410977999643"
receipt.cae_expires_on  # => #<Date: 2026-10-19>

File.binwrite("factura.pdf", receipt.pdf(copies: %i[original duplicate]))
```

## Documentación

| Guía | Qué cubre |
|---|---|
| [Configuración](docs/configuracion.md) | Certificado, servicios y punto de venta en ARCA; `Credentials`, `Issuer`, `PointOfSale`; tickets de WSAA; registro de llamadas |
| [Emitir comprobantes](docs/emision.md) | `Invoicer`: letras, importes, servicios, persistencia, reintentos, notas de crédito y débito |
| [PDF](docs/pdf.md) | Copias, logo, borradores, proformas y comprobantes que no pasan por el `Invoicer` |
| [Padrón](docs/padron.md) | Consulta de CUIT y alta del emisor desde ARCA |
| [Integración con Rails](docs/rails.md) | Configuración por entorno, Solid Cache, jobs, modelos y tests |
| [Homologación](docs/homologacion.md) | Diferencias con producción, CUITs de prueba y `bin/smoke` |
| [Errores](docs/errores.md) | Jerarquía de errores, qué reintentar y códigos de ARCA frecuentes |
| [Bajo nivel](docs/bajo-nivel.md) | `Client`, `Request`, `Wsfe`, `Padron`, `Qr` y `Soap` |

## Alcance

**Incluye:**
- WSFEv1: facturas y notas de crédito y débito A, B y C;
- conceptos 1, 2 y 3;
- pesos y una alícuota de IVA por comprobante;
- padrón A5 (constancia de inscripción).

**Todavía no incluye:**
- importes exentos, no gravados u otros tributos;
- varias alícuotas en un mismo comprobante;
- Factura de Crédito Electrónica MiPyME;
- moneda extranjera;
- CAEA;
- exportación (WSFEX).

## Versiones

La gema sigue [SemVer](https://semver.org/lang/es/). Mientras esté en 0.x, una
versión menor puede cambiar la API; el [CHANGELOG](CHANGELOG.md) lo detalla.
Fijá un tag en el `Gemfile`.

## Contribuir

Ver [CONTRIBUTING.md](CONTRIBUTING.md). Para reportar un problema de seguridad,
ver [SECURITY.md](SECURITY.md).

## Licencia

[MIT](LICENSE). Las fuentes Noto Sans incluidas se distribuyen bajo la
[SIL Open Font License](lib/arca/pdf/fonts/OFL.txt).
