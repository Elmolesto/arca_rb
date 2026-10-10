# Padrón

`Arca::PadronClient` consulta la constancia de inscripción de un CUIT (padrón
A5). Sirve para validar clientes y para completar los datos del emisor.

```ruby
padron = Arca::PadronClient.new(credentials:)
person = padron.find_person(tax_id: "30-71234567-1")

person.tax_id               # "30712345671"
person.legal_name           # "MI EMPRESA S.A." o "GONZALEZ MARIA"
person.fiscal_address       # "AV CORRIENTES 1234, CIUDAD AUTONOMA BUENOS AIRES, 1043"
person.vat_condition        # :responsible_registered, :monotributo o :vat_exempt
person.activity_started_on  # Date
person.active?              # false si la clave no está ACTIVA
```

El certificado tiene que tener asociado el servicio del padrón:
- `ws_sr_constancia_inscripcion` en producción;
- `ws_sr_padron_a5` en homologación.

## Errores

| Error | Cuándo |
|---|---|
| `Arca::PadronClient::NotFound` | El CUIT no existe o no tiene constancia de inscripción |
| `Arca::Rejection` | Otro rechazo, por ejemplo un servicio no asociado al certificado ("Computador no autorizado") |
| `Arca::TransientError` | ARCA no respondió; se puede reintentar |

`NotFound` hereda de `Rejection`, así que un `rescue Arca::Rejection` también lo
atrapa. Rescatalo primero si querés tratarlo aparte:

```ruby
begin
  person = padron.find_person(tax_id:)
rescue Arca::PadronClient::NotFound
  # CUIT inexistente: pedile al usuario que lo revise
end
```

## Dar de alta el emisor

```ruby
issuer = Arca::Issuer.from_padron(person, gross_income: "901-123456-7")
```

ARCA no informa los ingresos brutos y a veces tiene el domicilio desactualizado.
Mostrale los datos al usuario para que los confirme o corrija antes de
guardarlos.

## En homologación

El padrón de homologación sólo conoce algunos CUITs de prueba y contesta "no
existe" para cualquier otro. Para que los flujos se puedan probar, en
homologación la gema reemplaza cada consulta por un CUIT de prueba del mismo
tipo de persona:

- `20221124643` para personas humanas;
- `30111111118` para personas jurídicas.

Por eso, en homologación, `person.tax_id` y los demás datos son los de la
persona de prueba, no los del CUIT consultado. Si tu app copia esos datos (por
ejemplo, la razón social de un cliente), no lo hagas en homologación. Ver
[Homologación](homologacion.md).
