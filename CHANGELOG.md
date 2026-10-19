# Changelog

## 0.5.1

- El PDF sigue el modelo impreso de ARCA: el comprobante C lleva los totales
  en un cuadro, el domicilio comercial entra en una línea, el número de página
  va junto al CAE y la leyenda de responsabilidad es la de ARCA. Las alícuotas
  de IVA y los otros tributos en cero ya no se imprimen.

## 0.5.0

- `Arca::Credentials` lee el CUIT del dueño del certificado del propio
  certificado (`serialNumber=CUIT ...`); `cuit:` pasa a ser opcional.
- `Credentials#certificate_cuit` y `validate!` avisa si el `cuit:` configurado
  no es el del certificado.
- `bin/smoke` ya no necesita `ARCA_CUIT`.

## 0.4.2

- CI en Ruby 3.3, 3.4 y 4.0 con `actions/checkout` v7, y Dependabot para gemas
  y actions.
- Tests con minitest 6.
- `lib/arca` se ordena en carpetas por capa (`configuration`, `fiscal`,
  `services`, `pdf`, `support`). Los nombres de las clases no cambian.
- Carga `cgi/escape` en lugar de `cgi`, que Ruby 4.0 eliminó y hacía que la
  gema mostrara un aviso al cargarse.

## 0.4.1

- Repositorio público con licencia MIT.
- Documentación de uso en `docs/`: configuración, emisión, PDF, padrón,
  integración con Rails, homologación, errores y API de bajo nivel.
- Los tests y ejemplos usan datos ficticios.
- CI en Ruby 3.3 y 3.4.

## 0.4.0

- `Arca::Pdf.render(document, proforma: { title:, number: })` imprime un
  borrador como documento comercial propio (orden de compra, cotización): letra
  X, número de la app, sin punto de venta, CAE ni QR.
- `Arca::PadronClient::NotFound` (`< Rejection`) cuando el CUIT no existe o no
  tiene constancia, para distinguirlo de otros rechazos del padrón.

## 0.3.0

- Notas de débito A, B y C (códigos 2, 7 y 12) e
  `Invoicer#prepare_debit_note`. Las notas de crédito pueden asociar una nota
  de débito.
- `Client#points_of_sale` y `verify_point_of_sale!` (también en el
  `Invoicer`) contra `FEParamGetPtosVenta`. En homologación no verifica nada,
  porque ARCA no registra puntos de venta ahí.
- `Credentials#certificate_expires_at` y `certificate_expires_within?`.
- `Soap::Transport.new(on_request:)` recibe un `Soap::Event` por cada llamada,
  con el XML sin token, firma ni ticket. El `Invoicer` acepta `transport:`.
- El cuadro de la Ley 27.743 sólo se imprime en comprobantes B a consumidor
  final.
- `bin/smoke` para probar contra homologación y CI con GitHub Actions.

## 0.2.0

Reemplaza `afipws` por clientes SOAP propios. Cambia la API de bajo nivel;
el `Invoicer`, `Request`, `Pdf` y el resto de la capa de arriba siguen igual.

- `Arca::Wsaa`, `Arca::Wsfe` y `Arca::Padron` hablan SOAP 1.1 con Net::HTTP y
  Nokogiri. Sin Savon (y sin la excepción de `bundler-audit` que obligaba su
  versión) ni ActiveSupport.
- El detalle de WSFE se arma en el orden del WSDL vigente, que incluye
  `CondicionIVAReceptorId`.
- `Credentials#ticket_store` reemplaza a `ticket_directory`: `TicketStore::File`,
  `TicketStore::Cache` (Rails.cache, para Heroku) y `TicketStore::Memory`.
  Si otro proceso ya obtuvo el ticket, se toma del almacenamiento en vez de
  fallar; si se perdió, el error lo explica.
- `Client` y `PadronClient` reciben `transport:` (tiempos de espera) en lugar
  de `afipws_options:`; el `wsfe:` y el `service:` inyectados siguen la
  interfaz de `Arca::Wsfe` y `Arca::Padron`.
- Los rechazos de WSFE juntan códigos de observaciones y de errores.
- Se agrega la dependencia `nokogiri` y se declara `base64`.

## 0.1.0

Primera versión, a partir de dos integraciones con ARCA que se usaban en
aplicaciones Rails.

- `Arca::Credentials` concentra entorno, CUIT representante y certificado para
  ambos clientes.
- Tipos de comprobante, condición IVA y documentos aceptan símbolo o código ARCA.
- Factura A también para receptores monotributistas (RG 5003).
- `vat_discriminated` sólo es verdadero para A; `vat_charged` indica si el
  comprobante lleva IVA (A y B).
- Alícuotas configurables (`vat_rate:`) y `VatRate.split` para totales con IVA.
- Los rechazos dejan el texto del proveedor en `diagnostics`, no en `message`.
- `PadronClient::Person#tax_id` es un String.
- `Arca::Qr` recibe campos explícitos en lugar de un `fiscal_payload`.
- `Arca::Pdf` genera el comprobante con datos
  tipados (`Arca::Pdf::Document`) en lugar de `fiscal_payload`: copias
  (original, duplicado, triplicado), logo, columna de unidad de medida en A y B,
  todas las alícuotas en A, régimen de transparencia fiscal (Ley 27.743) en B,
  comprobantes asociados, observaciones, número de página por copia y
  paginación que aprovecha las hojas intermedias.
- Nombre de la gema: `arca_rb`.
- `Arca::Invoicer` emite en dos pasos (`prepare` / `authorize`): elige la
  letra, deriva los importes de los ítems, reserva el número y, al reintentar,
  recupera el comprobante ya autorizado en vez de emitir otro.
  `prepare_credit_note` acredita total o parcialmente una factura.
- `Arca::Issuer` (con `from_padron`) y `Arca::PointOfSale` con el domicilio
  comercial de la sucursal, que es el que imprime el PDF.
- `Arca::Draft` e `Arca::IssuedReceipt` se guardan como JSON (`to_h`) y se
  reconstruyen (`from_h`) para reintentar o reimprimir.
- `Arca::ReceiptNumberTaken` cuando otro comprobante usó el número reservado.
- `Client::Receipt` incluye `receiver_document_number`.
- Concepto 2 y 3 (servicios): `Request` acepta `concept:` y `service_period:`
  y WSFE recibe `FchServDesde`, `FchServHasta` y `FchVtoPago`. El `Invoicer`
  lo elige solo cuando hay período facturado.
- El ticket de WSAA se guarda en `Credentials#ticket_directory` con el CUIT
  del certificado como clave. Antes `afipws` usaba el CUIT emisor, y con varios
  emisores delegados en un mismo certificado pedía tickets de más.
