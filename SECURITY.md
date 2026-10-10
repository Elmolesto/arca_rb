# Seguridad

## Reportar una vulnerabilidad

No abras un issue público. Usá [*Report a vulnerability*](https://github.com/Elmolesto/arca_rb/security/advisories/new)
en la pestaña *Security* del repositorio. Respondemos dentro de una semana.

## Buenas prácticas al usar la gema

- **Clave privada.** La clave del certificado da acceso a la facturación del
  CUIT. Guardala en un gestor de secretos o en credentials cifradas, nunca en el
  repositorio, en logs ni en jobs serializados.
- **Logs.** `Arca::Credentials#inspect` oculta el certificado y la clave. El
  callback `on_request` recibe el XML con el token y la firma filtrados, pero
  con los datos fiscales de los receptores: no lo guardes donde no corresponda.
- **Mensajes de error.** `Arca::Rejection#diagnostics` trae el texto de ARCA,
  que puede repetir datos del pedido. `message` sólo trae los códigos.
- **Entorno.** Elegí el entorno en el código según dónde corre la app, para que
  un entorno de prueba no pueda emitir en producción.
