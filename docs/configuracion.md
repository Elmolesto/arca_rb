# Configuración

Para emitir hacen falta tres cosas de ARCA y tres objetos de la gema.

| En ARCA | En la gema |
|---|---|
| Un certificado digital (clave privada + certificado) | `Arca::Credentials` |
| Servicios asociados al certificado (`wsfe`, padrón) | — |
| Un punto de venta habilitado para web services | `Arca::PointOfSale` |
| Los datos fiscales del emisor | `Arca::Issuer` |

## 1. Certificado

ARCA autentica cada llamada con un certificado X.509 emitido para un CUIT. Los
de homologación y producción son distintos y se tramitan por separado.

Generá la clave privada y el pedido de certificado (CSR):

```bash
openssl genrsa -out arca.key 2048
openssl req -new -key arca.key -out arca.csr \
  -subj "/C=AR/O=Mi Empresa SA/CN=facturacion/serialNumber=CUIT 30712345671"
```

Después, con clave fiscal:

- **Homologación:**
  1. Entrá al servicio *WSASS – Autogestión Certificados Homologación*, pegá el
     CSR y guardá el certificado que devuelve como `arca.crt`.
  2. En el mismo servicio, creá una autorización para cada servicio que vayas
     a usar: `wsfe` y `ws_sr_padron_a5`.
- **Producción:**
  1. En *Administración de Certificados Digitales*, creá un alias y subí el CSR.
  2. En *Administrador de Relaciones de Clave Fiscal*, asociá ese alias a los
     servicios *Facturación Electrónica* (`wsfe`) y, si consultás el padrón,
     *Consulta de constancia de inscripción* (`ws_sr_constancia_inscripcion`).

El certificado dura dos años. Guardá la clave privada como un secreto: nunca en
el repositorio ni en logs.

## 2. Punto de venta

En *Administración de puntos de venta y domicilios*, creá un punto de venta del
tipo web services. Para monotributo es *Factura Electrónica - Monotributo -
Web Services*; para responsables inscriptos es *RECE para aplicativo y web
services*. El número es el que va en `Arca::PointOfSale`.

En homologación no hace falta: ARCA acepta cualquier número.

## 3. Credenciales

```ruby
credentials = Arca::Credentials.new(
  environment: :production,            # o :homologation
  certificate_pem: ENV.fetch("ARCA_CERTIFICATE"),
  private_key_pem: ENV.fetch("ARCA_PRIVATE_KEY"),
  ticket_store: Arca::TicketStore::Cache.new(Rails.cache)
)

credentials.cuit                        # "30712345671", leído del certificado
credentials.validate!                   # CUIT, par certificado/clave y vencimiento, sin llamar a ARCA
credentials.certificate_expires_at      # => 2028-08-02 12:00:00 UTC
credentials.certificate_expires_within?(30 * 86_400)
```

ARCA escribe el CUIT del dueño en el certificado (`serialNumber=CUIT ...`), y
`Credentials` lo lee de ahí. Se puede pasar `cuit:` para un certificado que no
lo tenga; si los dos no coinciden, `validate!` lo avisa.

`environment` sólo acepta `:homologation` y `:production`. Elegilo en tu código
según el entorno de la app, no desde un archivo de configuración editable: así
un error de configuración en staging no puede emitir comprobantes reales (ver
[Integración con Rails](rails.md)).

`inspect` oculta el certificado y la clave, así que un `credentials` en un log
o en una excepción no los expone.

### Emitir por otro CUIT

El certificado puede pertenecer a un CUIT, por ejemplo un estudio contable o
una persona, y emitir por otro que le delegó el servicio `wsfe` en el
*Administrador de Relaciones de Clave Fiscal*. En ese caso `credentials.cuit`
es el dueño del certificado y `issuer.cuit` el de quien factura. La app sólo
configura el del emisor: el otro sale del certificado.

## 4. Ticket de acceso (WSAA)

ARCA entrega un ticket por certificado y servicio, válido hasta 12 horas.
Mientras ese ticket sigue vigente, rechaza pedir otro ("El CEE ya posee un TA
válido"). Por eso la gema guarda el ticket en `ticket_store` y lo reutiliza.

Ese almacenamiento tiene que cumplir dos condiciones:
- sobrevivir a deploys y reinicios;
- ser el mismo para todos los procesos que hablan con ARCA.

| Dónde corre la app | `ticket_store:` |
|---|---|
| Heroku, varios servidores o web + workers | `Arca::TicketStore::Cache.new(Rails.cache)` con Solid Cache, Redis o Memcached |
| Un servidor con disco persistente | `Arca::TicketStore::File.new("/rails/storage/arca")` |
| Tests y scripts | `Arca::TicketStore::Memory.new` |

Sin `ticket_store` se usa `TicketStore::File` en `tmp/arca`, que alcanza en
desarrollo. Sirve cualquier objeto que responda a `read(key)` y
`write(key, value, expires_in:)`.

La clave incluye el CUIT del certificado, el entorno y el servicio, así que
todos los emisores que delegan en el mismo certificado comparten el ticket.

Si dos procesos piden el ticket a la vez, ARCA rechaza al segundo. La gema
espera unos segundos y toma el que guardó el primero.

Si el ticket se perdió (el almacenamiento no es compartido o se borró), lanza
`Arca::TransientError`: hay que esperar a que el ticket anterior venza, como
máximo 12 horas. Por eso un almacenamiento no compartido en producción es un
error de configuración.

## 5. Emisor

```ruby
issuer = Arca::Issuer.new(
  cuit: "30712345671",
  legal_name: "Mi Empresa S.A.",
  vat_condition: :responsible_registered,   # :monotributo, :vat_exempt
  fiscal_address: "Av. Corrientes 1234, CABA",
  gross_income: "901-123456-7",              # opcional, se imprime tal cual
  activity_started_on: "2019-04-01"          # opcional, Date o ISO 8601
)
```

Se puede completar desde el padrón con `Arca::Issuer.from_padron` (ver
[Padrón](padron.md)). Guardalo en tu app y dejá que se corrija a mano: ARCA no
informa los ingresos brutos y a veces el domicilio está desactualizado.

| `vat_condition` | Condición | Emite |
|---|---|---|
| `:responsible_registered` | IVA Responsable Inscripto | A y B |
| `:monotributo` | Responsable Monotributo | C |
| `:vat_exempt` | IVA Sujeto Exento | C |

## 6. Punto de venta

```ruby
Arca::PointOfSale.new(number: 3)
Arca::PointOfSale.new(number: 4, commercial_address: "Rivadavia 100, Moreno", name: "Sucursal Moreno")
```

ARCA asocia cada punto de venta a un domicilio, pero no lo devuelve por web
service. Si facturás desde una sucursal, cargá su domicilio en
`commercial_address`: es el que imprime el PDF como *Domicilio Comercial*. Sin
él se imprime el domicilio fiscal del emisor.

Para confirmar que el punto de venta está habilitado, no bloqueado ni dado de
baja, conviene verificarlo al darlo de alta en la app:

```ruby
invoicer.verify_point_of_sale!   # Arca::ConfigurationError si no sirve
```

En homologación no verifica nada, porque ARCA no registra puntos de venta.

## 7. Registro de llamadas y tiempos de espera

`Arca::Soap::Transport` hace las llamadas HTTP. Se le pasa a `Invoicer`,
`Client` y `PadronClient`:

```ruby
transport = Arca::Soap::Transport.new(
  open_timeout: 10,    # valores por defecto
  read_timeout: 60,
  on_request: ->(event) do
    logger.info("ARCA #{event.operation} #{event.status} #{(event.duration * 1000).round}ms")
    logger.debug(event.response) if event.failed?
  end
)

Arca::Invoicer.new(credentials:, issuer:, point_of_sale:, transport:)
Arca::PadronClient.new(credentials:, transport:)
```

Cada `event` trae:
- `operation`, `url`, `status` y `duration` (en segundos);
- `request` y `response`, con el XML;
- `error`, y `failed?`.

En el XML, el token, la firma, el pedido de login firmado y el ticket de WSAA
vienen reemplazados por `[FILTRADO]`. Igual contiene datos fiscales de tus
clientes, así que guardalo sólo donde corresponda. Si el callback falla, la
gema lo avisa por `warn` y la llamada a ARCA sigue.

En producción WSFE exige una configuración TLS antigua de OpenSSL
(`DEFAULT@SECLEVEL=1`); la gema la aplica sola sólo en esa conexión.
