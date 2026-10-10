# Contribuir

Gracias por querer mejorar arca_rb. Los issues y pull requests son
bienvenidos.

## Preparar el entorno

```bash
git clone https://github.com/Elmolesto/arca_rb.git
cd arca_rb
bundle install
bundle exec rake test
bundle exec rubocop . bin/smoke
```

Requiere Ruby 3.3 o superior. El CI corre los tests en Ruby 3.3, 3.4 y 4.0 y RuboCop en
cada push a `main` y en cada pull request.

## Estructura del código

`lib/arca` se agrupa por capa:

| Carpeta | Qué contiene |
|---|---|
| `lib/arca/` | La emisión (`Invoicer`, `Draft`, `IssuedReceipt`), los errores y la versión |
| `configuration/` | `Credentials`, `Environment`, `TicketStore`, `Issuer` y `PointOfSale` |
| `fiscal/` | Reglas fiscales: `Identity`, `VatCondition`, `VatRate`, `ReceiptType`, `ServicePeriod`, `Request` y `Pricing` |
| `services/` | Los servicios de ARCA (`Soap`, `Wsaa`, `Wsfe`, `Padron`) y los clientes (`Client`, `PadronClient`) |
| `pdf/` | `Document`, `Renderer`, `Format`, `Qr` y las fuentes |
| `support/` | Utilidades internas (`Serialization`) |

Las carpetas no son namespaces: todas las clases viven directamente bajo
`Arca` (`Arca::ReceiptType`, `Arca::Wsfe`), salvo las de `pdf/`, que están
bajo `Arca::Pdf`, y `Arca::Qr`. `lib/arca_rb.rb` las carga en orden. Los
tests siguen la misma estructura en `test/arca/`.

## Pautas

- **Sin Rails.** La gema no puede depender de Rails ni de ActiveSupport; un test
  lo verifica (`test/arca/framework_independence_test.rb`).
- **Tests sin red.** Simulan ARCA con `FakeTransport` y respuestas SOAP de
  ejemplo (ver `test/test_helper.rb`). Ninguno llama a ARCA.
- **Cambios que tocan a ARCA.** Si un cambio afecta lo que se envía a ARCA,
  corré `bin/smoke` contra homologación con tu certificado (ver
  [Homologación](docs/homologacion.md)) y contá el resultado en el PR.
- **Datos ficticios.** Nunca subas certificados, claves, tickets ni CUITs o
  datos de personas reales. Para ejemplos usá los CUITs de prueba de ARCA
  (`20111111112`, `20221124643`, `30111111118`) o números ficticios con dígito
  verificador válido.
- **Idioma.** Los mensajes de error para el usuario y la documentación van en
  español; el código y sus comentarios, en inglés.
- **Documentación.** Si cambiás la API, actualizá `docs/` y agregá una entrada
  en `CHANGELOG.md` bajo *Sin publicar*.

## Publicar una versión

1. Actualizá `Arca::VERSION` en `lib/arca/version.rb`, el tag de ejemplo en el
   README y el `CHANGELOG.md`.
2. Commiteá y creá el tag `vX.Y.Z`.
3. Hacé push del commit y del tag.
