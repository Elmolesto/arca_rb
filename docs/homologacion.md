# Homologación

Homologación es el entorno de prueba de ARCA. Los comprobantes que se emiten
ahí no tienen efecto fiscal. Se usa con `environment: :homologation` y un
certificado de homologación (ver [Configuración](configuracion.md)).

## Diferencias con producción

| | Homologación | Producción |
|---|---|---|
| WSAA | `wsaahomo.afip.gov.ar` | `wsaa.afip.gov.ar` |
| WSFE | `wswhomo.afip.gov.ar` | `servicios1.afip.gov.ar` |
| Padrón | `awshomo.afip.gov.ar` | `aws.afip.gov.ar` |
| Servicio del padrón | `ws_sr_padron_a5` | `ws_sr_constancia_inscripcion` |
| Puntos de venta | No registra ninguno; acepta cualquier número | Los habilitados para web services |
| Padrón | Sólo CUITs de prueba | Todos |

Consecuencias:

- `verify_point_of_sale!` no verifica nada en homologación.
- `PadronClient` consulta siempre un CUIT de prueba: `20221124643` para
  personas humanas y `30111111118` para jurídicas (ver [Padrón](padron.md)).
- `Issuer.from_padron` en homologación trae los datos del CUIT de prueba, no
  los tuyos.
- El CUIT de prueba `30111111118` está marcado como "sujeto no confiable":
  ARCA rechaza comprobantes con ese receptor (código 10248). Para un receptor
  identificado usá `20221124643` o un consumidor final sin identificar.
- La numeración avanza con cada prueba y no se puede reiniciar. Si varias
  personas o apps prueban con el mismo certificado y punto de venta, los
  números van a saltar.

## Usar homologación en todos los entornos menos producción

Elegí el entorno en el código según dónde corre la app, no desde un archivo de
configuración. Así un staging mal configurado no puede emitir comprobantes
reales:

```ruby
environment = ENV["APP_ENV"] == "production" ? :production : :homologation
```

En Rails, ver [Integración con Rails](rails.md).

## Probar contra ARCA real: `bin/smoke`

`bin/smoke` recorre la gema de punta a punta contra homologación:

- certificado y login en WSAA;
- puntos de venta;
- una factura de servicios, su reintento y su consulta;
- notas de débito y crédito;
- un número tomado;
- el padrón;
- los PDFs.

Desde un clon del repositorio:

```bash
ARCA_CUIT=20111111112 ARCA_POINT_OF_SALE=3 ARCA_CERTIFICATE=cert.pem ARCA_PRIVATE_KEY=key.pem bin/smoke
```

| Variable | |
|---|---|
| `ARCA_CUIT` | CUIT dueño del certificado |
| `ARCA_POINT_OF_SALE` | Cualquier número en homologación |
| `ARCA_CERTIFICATE`, `ARCA_PRIVATE_KEY` | Ruta o el PEM |
| `ARCA_VAT_CONDITION` | Condición del emisor; `monotributo` por defecto |
| `ARCA_TICKET_DIR` | Dónde guardar el ticket de WSAA; `tmp/arca` por defecto |
| `ARCA_OUTPUT` | Dónde guardar los PDFs; `tmp/smoke` por defecto |
| `ARCA_LOG=1` | Muestra cada llamada SOAP |

Termina con código 1 si falla algún paso. Nunca habla con producción.
