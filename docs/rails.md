# Integración con Rails

La gema no depende de Rails. Esta guía muestra una forma de integrarla, basada
en una app que factura en producción con Solid Queue y Solid Cache.

## Configuración por entorno

Guardá el certificado y los datos del emisor en las credentials cifradas. El
entorno de ARCA sale de `Rails.env`, no de las credentials: sólo producción
emite comprobantes reales.

```yaml
# bin/rails credentials:edit --environment production
arca:
  certificate_pem: |                            # el CUIT del dueño sale de acá
    -----BEGIN CERTIFICATE-----
    ...
  private_key_pem: |
    -----BEGIN PRIVATE KEY-----
    ...
  issuer:                                       # quien factura
    cuit: "30712345671"
    point_of_sale: 3
    legal_name: Mi Empresa S.A.
    vat_condition: responsible_registered
    fiscal_address: Av. Corrientes 1234, CABA
    commercial_address: Rivadavia 100, Moreno   # opcional
    gross_income: "901-123456-7"                # opcional
    activity_started_on: "2019-04-01"
```

```ruby
# app/models/arca_config.rb
module ArcaConfig
  extend self

  def environment = Rails.env.production? ? :production : :homologation

  def invoicer = Arca::Invoicer.new(credentials:, issuer:, point_of_sale:, transport:)
  def padron_client = Arca::PadronClient.new(credentials:, transport:)

  def credentials
    Arca::Credentials.new(
      environment:,
      certificate_pem: settings[:certificate_pem],
      private_key_pem: settings[:private_key_pem],
      ticket_store:
    )
  end

  def issuer = Arca::Issuer.new(**settings.fetch(:issuer).except(:point_of_sale, :commercial_address))

  def point_of_sale
    Arca::PointOfSale.new(number: settings.dig(:issuer, :point_of_sale), commercial_address: settings.dig(:issuer, :commercial_address))
  end

  # Para los tests, que no tienen credentials de ARCA.
  attr_writer :settings

  private

  def settings = @settings || Rails.application.credentials.arca || {}

  # La web y los jobs comparten el ticket de WSAA.
  def ticket_store
    return Arca::TicketStore::File.new(Rails.root.join("tmp/arca").to_s) if Rails.env.local?

    Arca::TicketStore::Cache.new(Rails.cache)
  end

  def transport
    Arca::Soap::Transport.new(on_request: ->(event) {
      Rails.logger.info("ARCA #{event.operation} status=#{event.status} duration=#{(event.duration * 1000).round}ms")
    })
  end
end
```

`Rails.cache` tiene que ser compartido entre procesos y persistente, como Solid
Cache, Redis o Memcached. `:memory_store` y `:null_store` no sirven fuera de
desarrollo (ver [Ticket de acceso](configuracion.md#4-ticket-de-acceso-wsaa)).

No loguees `event.request` ni `event.response` en producción: llevan datos
fiscales de tus clientes.

## Modelo

Guardá el borrador y el comprobante emitido en una columna `jsonb`, junto con
las columnas que quieras consultar:

```ruby
add_column :invoices, :arca, :jsonb, default: {}, null: false
add_column :invoices, :receipt_number, :integer
add_column :invoices, :cae, :string
add_column :invoices, :status, :integer, default: 0, null: false   # pending, authorized, rejected
```

```ruby
class Invoice < ApplicationRecord
  enum :status, { pending: 0, authorized: 1, rejected: 2 }
  has_one_attached :pdf

  def draft = arca.present? && !authorized? ? Arca::Draft.from_h(arca) : nil
  def issued_receipt = authorized? ? Arca::IssuedReceipt.from_h(arca) : nil
end
```

## Emitir en un job

Emití en un job, no en el request, y en dos transacciones: una que reserva el
número y otra que guarda la autorización. La llamada a ARCA va afuera de las
dos, para no tener una transacción abierta mientras se espera la red.

```ruby
class AuthorizeInvoiceJob < ApplicationJob
  # ARCA numera por punto de venta: una autorización a la vez.
  limits_concurrency to: 1, key: ->(_invoice) { "arca-invoicing" }, duration: 15.minutes

  retry_on Arca::TransientError, wait: :polynomially_longer, attempts: 5

  def perform(invoice)
    return if invoice.authorized?

    invoicer = ArcaConfig.invoicer
    draft = invoice.with_lock do
      invoice.draft || invoicer.prepare(receiver: invoice.receiver, items: invoice.items, issue_date: Date.current).tap do |draft|
        invoice.update!(arca: draft.to_h, receipt_number: draft.receipt_number)
      end
    end

    receipt = invoicer.authorize(draft)

    invoice.update!(status: :authorized, arca: receipt.to_h, receipt_number: receipt.number, cae: receipt.cae)
    invoice.pdf.attach(io: StringIO.new(receipt.pdf), filename: "factura-#{receipt.number}.pdf", content_type: "application/pdf")
  rescue Arca::ReceiptNumberTaken
    invoice.update!(arca: {}, receipt_number: nil)
    retry_job
  rescue Arca::Rejection => error
    invoice.update!(status: :rejected)
    Rails.logger.warn("ARCA rechazó la factura #{invoice.id}: #{error.codes.join(", ")}")
  end
end
```

- **`TransientError`.** El job reintenta con el mismo borrador. Si ARCA había
  autorizado, la gema recupera el comprobante.
- **`ReceiptNumberTaken`.** Se descarta el borrador y se prepara de nuevo.
- **Otro rechazo.** La factura queda rechazada con el borrador guardado. Antes
  de volver a intentar, confirmá que ARCA no tiene el número y limpiá el
  borrador (ver [Si ARCA rechaza](emision.md#si-arca-rechaza)).

`limits_concurrency` es de Solid Queue. Con otro backend, usá un lock (por
ejemplo `pg_advisory_lock`) para que dos procesos no preparen a la vez.

## Verificar la configuración

Conviene tener tareas que validen la configuración sin emitir:

```ruby
# lib/tasks/arca.rake
namespace :arca do
  task check: :environment do
    ArcaConfig.credentials.validate!
    puts "Certificado vence el #{ArcaConfig.credentials.certificate_expires_at.to_date}"
    ArcaConfig.invoicer.verify_point_of_sale!
    puts "Última factura B: #{ArcaConfig.invoicer.client.last_authorized_receipt(receipt_type: :invoice_b)}"
  end
end
```

Y un job recurrente que avise cuando el certificado está por vencer:

```ruby
class ArcaCertificateCheckJob < ApplicationJob
  def perform
    credentials = ArcaConfig.credentials
    return unless credentials.certificate_expires_within?(30.days, now: Time.current)

    raise "El certificado de ARCA vence el #{credentials.certificate_expires_at.to_date}"
  end
end
```

## Tests

Los tests no deberían llamar a ARCA. `Arca::Invoicer` acepta un `client:` que
reemplaza a `Arca::Client`. Tiene que responder a:
- `next_receipt_number(receipt_type:)`;
- `authorize(request:)`;
- `consult_receipt(receipt_type:, receipt_number:)`;
- `verify_point_of_sale!`.

```ruby
class FakeArcaClient
  attr_reader :requests

  def initialize = (@requests = []; @issued = {})

  def next_receipt_number(receipt_type:) = (@issued.keys.select { _1.first == receipt_type.code }.map(&:last).max || 0) + 1
  def verify_point_of_sale! = nil

  def authorize(request:)
    @requests << request
    authorization = Arca::Client::Authorization.new(number: request.receipt_number, cae: "7#{request.receipt_number.to_s.rjust(13, "0")}", expires_on: request.issue_date + 10)
    @issued[[ request.receipt_type.code, request.receipt_number ]] = [ authorization, request ]
    authorization
  end

  def consult_receipt(receipt_type:, receipt_number:)
    authorization, request = @issued[[ Arca::ReceiptType.fetch(receipt_type).code, receipt_number ]]
    return unless authorization

    Arca::Client::Receipt.new(number: authorization.number, cae: authorization.cae, expires_on: authorization.expires_on,
      total: request.total_amount, receiver_document_number: request.receiver.document_number)
  end
end

ArcaConfig.settings = { issuer: { cuit: "20111111112", point_of_sale: 3, legal_name: "Test", vat_condition: :monotributo } }
invoicer = Arca::Invoicer.new(credentials: ArcaConfig.credentials, issuer: ArcaConfig.issuer, point_of_sale: ArcaConfig.point_of_sale, client: FakeArcaClient.new)
```

Para simular errores, hacé que `authorize` lance `Arca::TransientError` o
`Arca::Rejection.new("...", codes: ["10016"])`.
