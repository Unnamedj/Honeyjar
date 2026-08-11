# 🍯 Honey Hub

Dashboard en vivo para el **Honey TP Collector**. Todas tus cuentas de Roblox
reportan a una misma pantalla: cuántos Honey Jars llevan en total, cuánto puso
cada una, a qué ritmo van, cuántos hops hicieron, en qué server están — y desde
ahí mismo las pausás, les cambiás el método o las hacés saltar de server.

**Cada usuario ve solo lo suyo.** Te registrás, el admin te habilita, recibís un
token propio, y las cuentas que usen ese token entran a *tu* panel. Dos personas
pueden estar
corriendo el mismo script (incluso con la misma cuenta de Roblox) y sus
contadores no se tocan: la clave del sistema es `(usuario, cuenta de Roblox)`,
nunca la cuenta sola.

---

## Cómo se ve

- **Cifra principal** con el honey total del equipo y KPIs de cuentas en vivo,
  ritmo de la última hora, hops y racha de días.
- **Gráfico de ritmo** (6 h / 24 h / 7 d) del equipo, que pasa a modo énfasis
  cuando elegís una cuenta: ella en ámbar, el equipo detrás como contexto.
- **Podio** de las tres que más juntaron.
- **Una tarjeta por cuenta**: avatar de Roblox, estado en vivo, total, sparkline
  de las últimas 3 h, hops, uptime, hace cuánto agarró el último jar, server y
  jugadores, método y velocidad — más los botones de control.
- **Ranking** con barras, y la misma tabla en versión texto.
- **Pestaña Usuarios**, solo para el admin: quién se registró, cuántas cuentas
  tiene cada uno, cuántas están reportando ahora mismo — y el botón que les
  habilita o les corta el loader.

---

## Deploy en Railway

1. **Creá el proyecto** desde este repo: *New Project → Deploy from GitHub repo*.
2. **Agregá Postgres**: *New → Database → Add PostgreSQL*. Railway inyecta
   `DATABASE_URL` solo; no hay que copiar nada.
3. **Definí `SESSION_SECRET`** en las variables del servicio:

   ```bash
   node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"
   ```

4. **Generá el dominio**: *Settings → Networking → Generate Domain*.
5. Entrá a ese dominio y **creá tu usuario**. El primero que se registra es el
   dueño; cuando ya estén todos, poné `ALLOW_SIGNUP=0` para cerrar el registro.

El esquema se aplica solo en cada arranque (`src/schema.sql` es idempotente), así
que no hay paso de migración manual.

### Variables

| Variable | Obligatoria | Qué hace |
|---|---|---|
| `DATABASE_URL` | sí | La inyecta el plugin de Postgres |
| `SESSION_SECRET` | sí | Firma las cookies. Si cambia, se cierran las sesiones (los tokens de bot siguen valiendo) |
| `PORT` | no | La define Railway; en local, 3000 |
| `BEAT_INTERVAL_MS` | no | Cada cuánto reporta el bot. Default 5000 |
| `ALLOW_SIGNUP` | no | `0` cierra el registro de usuarios nuevos |
| `MAX_USERS` | no | Tope de cuentas en el hub. Vacío o `0` = sin tope |
| `FETCH_TOKEN` | no | Secreto compartido para `/api/fetch/*` y para bajar los `.lua` |
| `PROXIES` | no | Proxies para el fetcher. Sin esto el fetcher queda apagado (ver abajo) |
| `FETCHER` | no | `1` prende el fetcher sin proxies, `0` lo apaga siempre |

### Correrlo local

```bash
cp .env.example .env      # apuntá DATABASE_URL a tu Postgres
npm install
npm start                 # http://localhost:3000
```

---

## Quién entra: el admin y el acceso

El **primer usuario que se registra es el admin** del hub. No hay flag ni
variable de entorno para eso: es el `id` más chico de la tabla, así que no se
puede apagar sin querer ni falsificar desde la UI.

Del segundo en adelante, registrarse **no alcanza**. Entran bloqueados: ven el
panel, pero no su token ni el loader, y `/api/bot/*` les rechaza los beats con
`403`. El admin tiene una pestaña **Usuarios** arriba a la derecha con cuántos
usuarios hay, cuántas cuentas creó cada uno, cuántas están reportando y cuántas
tienen el collector prendido — y el botón para darles o quitarles el acceso.

Quitar el acceso corta al instante: el beat siguiente ya se rechaza, no hace
falta esperar a que caduque ninguna sesión.

Los usuarios que ya existían cuando se agregó todo esto quedan habilitados
solos, para que un deploy no les corte los bots que están corriendo.

---

## Conectar una cuenta

En el panel, **＋ Conectar cuenta** te da el token y el snippet ya armado (si
todavía no te habilitaron, ahí mismo dice que falta la aprobación). Es una sola
línea, en el ejecutor:

```lua
loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua?token=hh_..."))(
    "https://tu-app.up.railway.app", "hh_..."
)
```

El token va **dos veces** y no es un error: en la URL para que el server te
entregue el archivo (los `.lua` no son públicos), y como argumento para que el
collector sepa a dónde reportar. `honey_hub.lua` es solo un loader: descarga el
collector (`honey_tp.lua`) con ese mismo token y lo arranca con esos dos
argumentos. El reporte a Railway y
el control remoto ya vienen integrados en el collector — no hay un segundo
paso ni un parche que pegar a mano (ver [`lua/PATCH.md`](lua/PATCH.md) si
veniás de una versión anterior).

El mismo token va en **todas** tus cuentas: se separan solas por usuario de
Roblox. En unos segundos aparecen en el panel con su avatar y su contador,
honey (total y por cuenta), ritmo, ranking, racha, hops, server, uptime, y los
botones de control ya funcionando.

---

## Cómo funciona

### El conteo de honey

El número no lo lleva el script aparte: lo lee del mismo contador que ve el
jugador en pantalla (`LeftBottom > LeftBottom > CurrencyHoney`). Por eso es el
real y no una estimación, e incluye lo que agarraste a mano y lo que la cuenta
ya tenía antes de prender el bot. El juego lo muestra entero o abreviado
("12.4K", "1.2M"), así que el script lo parsea antes de mandarlo. Si el label no
se puede leer, no manda nada: el panel se queda con la última lectura buena en
vez de pisar el total con un cero.

### Los hops

No se cuentan en Lua: el teleport corta la ejecución antes de que el script
alcance a reportar el salto. El server los deriva viendo cambiar el `jobId` entre
un beat y el siguiente.

### Los totales

Lo que reporta el bot **ya es el total de la cuenta**, así que el server lo
*pisa*, no lo suma: volver a correr el script — y el auto-hop lo reinicia en cada
salto — no vuelve a contar honey que ya estaba contado.

Lo que sí se acumula es la *ganancia* entre dos lecturas. La lectura anterior
queda en `accounts.honey_anchor`, en la cuenta y no en la sesión, porque la
sesión muere en cada teleport. Esa ganancia es la que llena las cubetas de 5
minutos (`samples`), de donde salen el gráfico, el ritmo, la racha y la mejor
hora del día. Si el número baja porque gastaste honey en el juego, se reancla y
la ganancia de ese beat es 0: el gráfico nunca resta.

### Los comandos

El dashboard encola; el bot los levanta en su siguiente beat y los ackea cuando
los aplicó. Mientras tanto la tarjeta muestra *orden pendiente*. Un comando del
mismo tipo sin entregar queda obsoleto apenas llega otro: si tocaste velocidad
tres veces seguidas, al bot le llega la última.

### El fetcher (servers frescos para el hop)

Sin fetcher, cada cuenta pagina `games.roblox.com` por su cuenta cada vez que
quiere saltar. Con varias cuentas eso son decenas de requests por minuto desde
la misma IP: llega el 429, el listado empieza a devolver nada, y el síntoma es
*"ni hace hop"*. Peor: todas leen la misma primera página, así que terminan
saltando **al mismo server**.

Con el fetcher, el panel scrapea el listado una sola vez, en segundo plano y
repartido entre proxies, y guarda los jobIds en un pool. El bot pide uno y se
lleva uno **reservado para él**: nadie más lo recibe hasta que vence la reserva.
Cero rate-limit del lado del bot, y dos cuentas nunca aterrizan juntas.

Cómo se prende: pegá tus proxies en `PROXIES` y listo — no hay nada que tocar en
el script. Con proxies residenciales tipo Nettify, el id de sesión va dentro del
usuario (`…-session-aub815-time-1`) y es lo que fija la IP de salida; el fetcher
lo **rota en cada request**, así que con un solo proxy ya tenés una IP distinta
por request. No hace falta pegar una lista larga.

El script degrada solo, en los dos sentidos: si el panel no está, no tiene el
fetcher prendido o el pool quedó vacío, `/api/fetch/server` contesta 503 y el
hop cae al listado directo de Roblox, exactamente como antes. Y si un jobId ya
se llenó entre el scrape y el salto, el teleport falla, el bot avisa por
`/api/fetch/drop` y ese server sale del pool en vez de repartirse a la siguiente
cuenta.

El panel lo muestra en **Pool de servers**: cuántos hay, cuántos quedan
disponibles, cuántos sin repartir, y los rate-limits y errores del scraper. Si
algo está mal configurado (sin proxies, o con proxies que no rotan la sesión) lo
dice ahí mismo con qué hacer al respecto.

Desde afuera del panel: `GET /api/fetch/stats` con el token del bot.

---

## API

### Bot (`Authorization: Bearer <token>`)

| Método | Ruta | Para qué |
|---|---|---|
| POST | `/api/bot/hello` | Registra la corrida, cierra las sesiones viejas |
| POST | `/api/bot/beat` | Heartbeat: manda estado, recibe comandos |
| POST | `/api/bot/bye` | Cierre limpio (al salir o teleportar) |
| GET | `/api/fetch/server?size=<n>&max=<jugadores>` | Pide jobIds del pool. `503 pool_vacio` si no hay |
| POST | `/api/fetch/drop` | `{jobId}` — ese server no sirve; lo saca del pool y devuelve reemplazo |
| GET | `/api/fetch/stats` | Estado del pool y de los proxies |

### Dashboard (cookie de sesión)

| Método | Ruta | Para qué |
|---|---|---|
| POST | `/api/auth/register` · `/login` · `/logout` | Sesión |
| GET | `/api/auth/me` | Usuario y token |
| POST | `/api/auth/token/rotate` | Token nuevo, el viejo muere |
| GET | `/api/overview?range=6h\|24h\|7d&tz=<min>` | Todo lo que pinta el panel, incluido el estado del pool de servers |
| POST | `/api/accounts/:id/command` | `enabled` `method` `speed` `autohop` `smart` `hop` |
| DELETE | `/api/accounts/:id` | Quitar una cuenta y su historial |

### Admin (cookie de sesión, solo el primer usuario)

| Método | Ruta | Para qué |
|---|---|---|
| GET | `/api/admin/overview` | Usuarios, cuentas por usuario, cuántas vivas y cuántas corriendo |
| POST | `/api/admin/users/:id/access` | `{approved: true\|false}` — da o saca el acceso al loader |

---

## Seguridad

- Contraseñas con bcrypt (12 rondas); sesión en cookie `httpOnly` + `sameSite`,
  y `secure` en producción.
- El `user_id` sale **siempre** de la cookie firmada, nunca del body. La
  pertenencia de una cuenta se chequea dentro del `WHERE` de la propia consulta,
  así no hay ventana entre verificar y escribir.
- Login con el mismo mensaje para usuario inexistente y contraseña incorrecta —
  y con el mismo tiempo: cuando el usuario no existe igual se corre un bcrypt
  contra un hash de descarte, porque una respuesta instantánea delata cuáles
  existen.
- La aprobación se chequea en el server en cada request, no escondiendo botones:
  sin acceso el token no viaja al panel y `/api/bot/*` contesta `403` aunque el
  usuario se lo haya guardado de antes. `/api/admin/*` es solo del primer
  usuario y devuelve `403` a cualquier otro, tenga o no la pestaña a la vista.
- Todos los valores que llegan del bot se recortan y se acotan antes de tocar la
  base; los comandos pasan por una lista blanca con validador por tipo.
- El token es lo único que separa un panel de otro: tratalo como una contraseña.
  Si se filtró, **Rotar token**.

### Límites de uso

En memoria, sin dependencias ni Redis, con ventana deslizante ([`src/lib/limit.js`](src/lib/limit.js)):

| Ruta | Límite | Nota |
|---|---|---|
| `POST /api/auth/register` | 3 por hora y por IP | crear cuentas cuesta un bcrypt de 12 rondas |
| `POST /api/auth/login` | 10 **fallidos** por 15 min y por IP | entrar bien no gasta cupo |
| `/api/fetch/*` | 600 por minuto y por IP | techo alto: decenas de bots desde una casa entran cómodos |

`MAX_USERS` es el freno duro: el límite por IP para al que insiste desde un
lado, el tope global para también al que reparte los intentos entre muchas IPs.
Con `ALLOW_SIGNUP=0` se cierra el registro del todo.

El estado vive en el proceso, así que se pierde en cada deploy (lo peor que
pasa es que alguien recupere sus intentos antes de tiempo) y **sería un límite
por instancia** si algún día el hub corre replicado.

### El código del collector

Los `.lua` **no se sirven desde `public/`**: viven en [`lua/`](lua/) y salen por
[`src/routes/scripts.js`](src/routes/scripts.js), que pide `?token=` — el de una
cuenta aprobada o el `FETCH_TOKEN` compartido. Sin token, `/honey_tp.lua`
devuelve un `401` con un comentario de Lua explicando por qué, así que pegar la
URL en el navegador no te da el collector. El token viaja en la query y no en un
header porque `game:HttpGet` no manda headers: es lo único que el ejecutor
puede hacer.

Lo que **no** se puede esconder, y conviene tenerlo claro: el HTML, el CSS y el
JS del panel los ejecuta el navegador, así que cualquiera que entre los puede
leer. Ahí no hay ningún secreto — los tokens, las consultas y las decisiones de
permiso están todas del lado del server, y el panel solo muestra lo que el
server le manda.

### Cabeceras

`X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`,
`Permissions-Policy`, HSTS en producción, y una CSP con `script-src 'self'` —
sin `unsafe-inline` para scripts, que es lo que convierte un XSS en nada. Por
eso el panel no tiene ni un `onclick=` en el HTML: todos los handlers se
enganchan desde el JS.

---

## Estructura

```
src/
  server.js          arranque, estáticos, manejo de errores
  db.js              pool de Postgres + migración al arrancar
  schema.sql         esquema, idempotente
  lib/auth.js        bcrypt, JWT en cookie, requireUser y requireAdmin
  lib/limit.js       límite de requests por ventana deslizante, en memoria
  lib/roblox.js      miniaturas de avatar con caché de 6 h
  routes/admin.js    usuarios del hub y quién tiene acceso al loader
  routes/auth.js     registro, login, token
  routes/scripts.js  entrega los .lua, solo con token válido
  routes/bot.js      ingesta de telemetría y entrega de comandos
  routes/dash.js     el overview que consume el panel
  routes/fetch.js    API del fetcher: dispensa jobIds, acepta descartes
  fetcher/pool.js    el pool de servers: scrapers, reserva, reciclado
  fetcher/proxies.js parseo de proxies y rotación del id de sesión
  fetcher/http.js    GET con JSON a través del túnel del proxy
public/
  index.html         login y registro
  panel.html         el dashboard
  css/style.css      sistema visual (tema oscuro único, deliberado)
  js/charts.js       gráficos en SVG a mano, sin librerías
  js/panel.js        estado, render y polling
lua/                 (fuera de public/: no se sirven sin token)
  honey_hub.lua      loader: descarga honey_tp.lua y lo arranca con (url, token)
  honey_tp.lua       el collector — movimiento, GUI, y el reporte a Railway integrado
  PATCH.md           notas para quien venía de la versión con parche manual
```

### Sobre los colores

La paleta sale de la GUI del collector (ámbar `#ffab21` sobre ciruela oscuro)
para que la web y el panel del juego se lean como la misma cosa. Los colores de
dato están validados contra la superficie `#1b161c`: el ramp ámbar pasa
monotonía de luminosidad, salto mínimo entre pasos y contraste del extremo claro;
los cuatro colores de estado pasan 3:1. El estado **nunca** se comunica solo con
color — siempre va punto + texto. Si tocás un hex, volvé a validar la paleta.
