# Errores

Todos los errores de la gema heredan de `Arca::Error`, salvo `InvalidRequest`,
que hereda de `ArgumentError`.

| Clase | Cuándo | ¿Reintentar? |
|---|---|---|
| `Arca::ConfigurationError` | Entorno, certificado, clave, CUIT o punto de venta mal configurados | No: corregir la configuración |
| `Arca::InvalidRequest` | El comprobante rompe una regla fiscal; no se envía a ARCA | No: corregir los datos |
| `Arca::TransientError` | ARCA no respondió (timeout, red, respuesta vacía) o el ticket de WSAA no está disponible todavía | Sí, con espera |
| `Arca::Rejection` | ARCA respondió y rechazó | No con los mismos datos |
| `Arca::ReceiptNumberTaken` | Otro comprobante usó el número reservado | Preparar el comprobante de nuevo |
| `Arca::PadronClient::NotFound` | El CUIT no existe o no tiene constancia | No |

`ReceiptNumberTaken` y `NotFound` heredan de `Rejection`.

## Rechazos

```ruby
rescue Arca::Rejection => error
  error.message      # "ARCA rechazó la autorización del comprobante (códigos ARCA: 10248)"
  error.codes        # ["10248"]
  error.diagnostics  # ["La CUIT receptora se encuentra limitada..."]
end
```

`message` sólo lleva los códigos, así que se puede mostrar al usuario o
guardar. El texto que devuelve ARCA va aparte en `diagnostics`, porque puede
repetir datos del pedido: revisalo antes de guardarlo o mostrarlo.

## Códigos frecuentes de WSFE

| Código | Significado | Qué hacer |
|---|---|---|
| 602 | No existe el comprobante consultado | La gema lo convierte en `nil` en `consult_receipt` |
| 10016 | El número o la fecha no son los que ARCA espera | Si es un reintento, la gema recupera el comprobante sola; si no, revisar la fecha de emisión |
| 10248 | El receptor está limitado por ARCA ("sujeto no confiable") | No se le puede facturar; en homologación pasa con `30111111118` |
| 600 | No se validó el token (fechas de generación y vencimiento) | Revisar el reloj del servidor |
| 601 | El CUIT emisor no está incluido en el token | El emisor no delegó `wsfe` en el CUIT del certificado |

La lista completa está en el manual de WSFEv1 de ARCA.

## Reintentos

- **`TransientError`:** se puede reintentar con espera, por ejemplo con
  `retry_on` en un job. En `authorize`, reintentá con el **mismo borrador**:
  si ARCA llegó a autorizar, la gema recupera el comprobante.
- **`ReceiptNumberTaken`:** descartá el borrador y llamá a `prepare` de nuevo.
- **Otros rechazos:** no reintentes con los mismos datos. Ver [Si ARCA
  rechaza](emision.md#si-arca-rechaza).
