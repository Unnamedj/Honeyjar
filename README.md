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

La interfaz está **en inglés**: el panel lo usan las cuentas que reparten el
loader, no solo vos. Los comentarios del código y este README siguen en
castellano — son para quien lo mantiene, no para quien lo usa.

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
- **KPI del evento Bee**: cuántas cuentas vivas están en un server con el evento
  corriendo. Si ese número es 0, el ritmo en cero no es un problema del bot.
- **Pestaña Users**, solo para el admin: quién se registró, cuántas cuentas
  tiene cada uno, cuántas están reportando ahora mismo — el botón que les
  habilita o les corta el acceso, y un chip por script para decidir cuáles
  puede usar cada uno.

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
| `PROXIES` | no | Proxies para el fetcher. Alternativa a `proxies.txt`. Sin ninguno de los dos el fetcher queda apagado (ver abajo) |
| `PROXY_FILE` | no | Usar otro archivo en vez de `proxies.txt` / `proxies1..10.txt` |
| `PROXY_STRIP_SESSION` | no | `0` respeta el `session-…` de cada línea (IP fija). Default: lo borra para que el gateway rote |
| `FETCHER` | no | `1` prende el fetcher sin proxies, `0` lo apaga siempre |
| `FETCH_WORKERS` | no | Scrapers en paralelo. Default 10 |
| `FETCH_MAX_PLAYERS` | no | Umbral de "server chico". Default 2 |
| `FETCH_RECYCLE_MS` | no | Cuánto queda reservado un jobId dispensado. Default 90000 |
| `FETCH_WIPE_MS` | no | Cada cuánto se tira el 80% de la caché. Default 2 h |
| `FETCH_MAX_SERVERS` | no | Techo del pool antes del freno. Default 50000 |

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
`403`. El admin tiene una pestaña **Users** arriba a la derecha con cuántos
usuarios hay, cuántas cuentas creó cada uno, cuántas están reportando y cuántas
tienen el collector prendido — y el botón para darles o quitarles el acceso.

Quitar el acceso corta al instante: el beat siguiente ya se rechaza, no hace
falta esperar a que caduque ninguna sesión.

Los usuarios que ya existían cuando se agregó todo esto quedan habilitados
solos, para que un deploy no les corte los bots que están corriendo.

### Permisos por script

`approved` es la puerta general; arriba de eso, cada usuario tiene un permiso
**por script**. En la pestaña Users hay un chip por cada uno (Collector,
Merchant) y se prenden y apagan de a uno.

Las reglas, en orden:

- el **admin** puede todos, siempre — si no, podría dejarse sin nada;
- **sin `approved` no puede ninguno**, tenga las filas que tenga: el permiso por
  script afina la puerta general, no la reemplaza;
- con fila en `user_scripts`, manda la fila;
- **sin fila, manda el default del catálogo**: `collector` viene en `true` y
  `merchant` en `false`. El collector es lo que ya estaba usando todo el mundo,
  así que el deploy no le corta los bots a nadie; lo que se agregue de ahora en
  más entra apagado y lo habilita el admin.

El corte es real, no cosmético: sin el permiso del collector `/api/bot/*`
contesta `403 collector_no_habilitado` en el beat siguiente, y la descarga del
`.lua` devuelve `401`. El permiso se resuelve en la **misma consulta** que ya
resolvía el token, así que no le agrega una query al beat.

---

## Los scripts que reparte el hub

Son dos, y cada uno se habilita por separado (ver *Quién entra*):

| Script | Qué hace | Entrada |
|---|---|---|
| **Collector** | Junta las jarras del evento Bee y reporta al panel | `honey_hub.lua` |
| **Merchant** | Compra selectiva y sniper del `BeeMerchantService` | `honey_merchant.lua` |

El catálogo vive en un solo lugar, [`src/lib/scripts.js`](src/lib/scripts.js): de
ahí salen las rutas que sirven los `.lua`, los toggles de la pestaña Users y los
snippets del modal. Sumar un tercero es agregar una entrada.

## Conectar una cuenta

En el panel, **＋ Connect account** te da el token y **un snippet por cada script
que tengas habilitado** (si todavía no te habilitaron, ahí mismo dice que falta
la aprobación).

**Collector** — una línea, en el ejecutor:

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

**Merchant** — es autocontenido, así que va sin argumentos:

```lua
loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_merchant.lua?token=hh_..."))()
```

El token acá sirve solo para bajarlo: el merchant no reporta al panel ni recibe
comandos, corre solo con su propia GUI.

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

### El evento Bee (y por qué el bot se queda quieto)

Las jarras solo existen mientras corre el evento **Bee**. Sin evento, un bot con
auto-hop se la pasa saltando de server en server sin juntar nada: gasta
teleports, se come rate-limits y no suma un jar. Por eso el script trackea el
evento y, con **Wait event** prendido (el default), **no junta ni hopea hasta
que arranca**.

La fuente buena es `ReplicatedStorage.Controllers.EventController`, que mantiene
`ActiveEvents` replicado y expone `:IsActive("Bee")`. Se llega a él **siempre
por `Env`**, nunca con un `require` crudo — y esa distinción es toda la
historia de esta sección.

#### Por qué el `require` crudo kickeaba

El problema nunca fue leer el evento: fue *desde dónde* se hacía la llamada. Una
llamada cruda desde el ejecutor se delata por tres lados a la vez:

- el `require` del ejecutor viene envuelto y **no pega en la caché real de
  Roblox**, así que re-ejecuta el módulo. Con `EventController` eso significa
  levantar `Synchronizer` + `ReplicatorClient` y terminar siendo un **segundo
  cliente de replicación** hablándole al server;
- la identidad del hilo es la elevada del ejecutor (7/8), no la **2** de un
  `LocalScript`;
- arriba de la llamada quedan nuestros frames, con el chunk name del
  `loadstring`, y un `getfenv(nivel)` desde el módulo los encuentra.

`Env` (en `honey_tp.lua`, portado de `honey_merchant.lua`) arma un espejo contra
las tres: usa el `require` **real del juego** vía `getrenv`, presta el entorno de
un `LocalScript` vivo con `getsenv`, baja la identidad a 2 mientras dura la
llamada, y hace nacer la llamada en un hilo aparte para que arriba del trampolín
no haya un solo frame nuestro. Con eso, `require` devuelve **la misma tabla que
ya tiene el cliente** — no ejecuta nada de nuevo.

Todo es best-effort: si el ejecutor no trae `getrenv`/`getsenv`/`setfenv`/
`setthreadidentity`, cada capa se cae sola y quedan las señales pasivas.

#### Las señales pasivas (respaldo)

Puro `FindFirstChild` y lectura de propiedades ya replicadas: no pueden kickear
porque el server no se entera. Son las huellas que el propio evento deja:

1. **La colmena**: `OnStart` pone `workspace.Beehive.Active.ActiveNeon` en
   `Transparency` 0, `OnStop` en 1. Es la única que es un booleano de verdad:
   sirve tanto para decir que sí como para decir que no.
2. **Las abejas**: el evento clona cada una como `Event Bee - <trait>` derecho
   en `Workspace` y las destruye al cortar. Es la mejor prueba positiva —
   siguen ahí aunque ya se hayan juntado todas las jarras, que es justo el
   hueco que dejaban las otras señales. Se indexan con la misma conexión de
   `DescendantAdded` que ya seguía a las jarras, así que no cuestan un barrido.
3. **Los VFX de la colmena**: `OnStart` prende `Beehive.BeeHiveSpawnVFX`. Solo
   confirma el sí. Con el Optimizer prendido no se consulta (esos emisores los
   apagamos nosotros) — y por eso el Optimizer deja la colmena afuera del
   barrido, para no quedarse ciego.
4. **Jarras en el mapa**: ver una es prueba de que el evento corre. No verlas no
   prueba nada, así que también es solo para el sí.

Sin ninguna señal se asume apagado, que es el lado seguro: esperar de más
cuesta menos que hopear en vacío.

> El resolvedor del remote `UseItem` (el gancho) siguió el mismo camino: se le
> sacó el `require` del paquete `Net`, que además se **reintentaba cada 3
> segundos** desde cada engage. Queda la huella dual-hash — el hash que existe
> como `RE` y `RF` a la vez solo puede ser `UseItem` — que es estructural y ya
> era la vía preferida.

Cada beat lleva el estado al panel, así que la tarjeta de la cuenta dice
*Waiting for event* en vez de un *Idle* que parecería un bot roto — y el KPI de
arriba muestra cuántas cuentas están efectivamente en el evento.

### El orden de recolección (Sweep vs Nearest)

Las jarras salen de un escaneo del workspace, y ese escaneo devuelve una tabla
hash: el orden que trae **no tiene ninguna relación con dónde están las jarras en
el mapa**. Hay que decidirlo, y hay dos formas — se elige con el toggle
**Single sweep**, dentro del popover de Smart TP (o con el comando `sweep` desde
el panel).

**Nearest** (el comportamiento histórico) elige, en cada paso, la jarra más
cercana a donde estás parado *en ese momento*. Reacciona a lo que aparezca y a
dónde terminaste realmente, pero es un *greedy* local: agarra la de al lado, y
entonces la mejor opción siguiente queda del otro lado del grupo. De ahí sale el
zigzag — el recorrido se parte en tramos sueltos y el total termina más largo
que si se hubiera planeado.

**Sweep** ordena el lote entero **una sola vez**, antes de moverse: un barrido
angular alrededor del centro del grupo, rotado para empezar por la jarra más
cercana. Un barrido angular nunca cruza el centro dos veces, así que el recorrido
no puede volver sobre sus pasos: queda un tour por el perímetro, un solo trazo.
Lo que se paga es que el orden queda fijo al principio y no se reacomoda si
aparece una jarra nueva a mitad del recorrido (si desapareció porque otra cuenta
la agarró, se descarta sin gastar el viaje).

Los dos usan **el mismo motor de movimiento**: Sweep decide *en qué orden* se
visitan, Smart TP decide *cómo* se viaja a cada una (gancho o carpet). Son
independientes y se combinan.

Viene en **Sweep** por defecto. Está como toggle justamente porque cuál gana
depende de cómo queden repartidas las jarras en el mapa: si en algún server rinde
mejor el viejo, se apaga y listo.

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

### El HUD del juego

Lo que se ve al entrar es un cartel chico en el medio, semitransparente: el
**total de honey de la cuenta**, si el evento está corriendo, y tres
interruptores — **Wait event**, **Anti-AFK** y **Boost FPS**. El total sale del
mismo contador que ve el jugador (`LeftBottom > LeftBottom > CurrencyHoney`),
que es exactamente el que ya se reportaba al panel: la lectura vive en un solo
lugar y la usan los dos, así no hay dos números distintos.

El panel completo (método, velocidad, hop, Smart TP y el orden de recolección)
**arranca minimizado** y queda detrás de la burbuja 🍯 de arriba.

**Anti-AFK** responde al `Idled` de Roblox con un click de `VirtualUser`: resetea
el contador de inactividad sin tocar nada del juego.

**Boost FPS** apaga partículas, humo, estelas, rayos y sombras del mapa para que
varias cuentas entren en la misma máquina. Arranca **apagado** a propósito, y
nunca toca tres cosas: lo que cuelga de una jarra (el claim depende del
`ProximityPrompt` de la jarra, romperlo es dejar de recolectar), los personajes,
y nada fuera de `workspace` — ahí vive la GUI. Tampoco apaga el render 3D: sin
él los `ProximityPrompt` dejan de mostrarse y el juego deja de reclamar las
jarras. Apagarlo deja de tocar lo nuevo; lo ya apagado vuelve con un rejoin.

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

Cómo se prende: pegá tus proxies en `proxies.txt` (o en la variable `PROXIES`) y
listo — no hay nada que tocar en el script. Se leen también `proxies1.txt` …
`proxies10.txt`, que es lo cómodo cuando son miles de líneas y no entran en el
textarea de Railway.

**Cómo trata las sesiones.** Los proveedores residenciales (Pulse, Nettify)
meten la configuración adentro del usuario:

```
usuario_session-abc123_lifetime-30:password@gateway.pulseproxy.com:8080
       ^ fija la IP de salida     ^ por cuántos minutos
```

Ese `session-…` es justo lo que un scraper no quiere: mientras no cambie, todo
sale por **una sola IP** y el 429 llega igual que sin proxy. El fetcher lo
**borra** antes de cada request y deja que el gateway rote solo, que es como
esperan que se los use Pulse y compañía. Es el comportamiento probado en
producción, y es mejor que inventar un id de sesión nuevo nosotros: si el
proveedor exige que el id sea uno que él asignó, uno inventado puede terminar
cayendo a una IP por defecto en vez de fallar limpio — indistinguible de un
rate-limit real. Si alguna vez querés la IP pinneada, `PROXY_STRIP_SESSION=0`
usa las líneas tal cual.

Tampoco hay lista negra de proxies. Con un gateway rotativo la línea que falló
no es "un proxy malo", es una IP de salida que salió mal, y la próxima ya es
otra; además, al borrarles la sesión, mil líneas del mismo gateway son la misma
credencial, así que castigar a una las sacaba a todas y dejaba al scraper
girando en falso. El único freno es el **delay adaptativo**: arranca en 100 ms,
sube 100 ms por cada 429 y baja 10 ms por cada respuesta buena.

El pool no expira servers de a uno. Cada 2 horas se tira el 80% de la caché y se
deja que los scrapers la rellenen con lo que el listado dice *ahora*; y si pasa
las 50.000 entradas y se queda ahí 50 minutos, wipe completo. Es lo que evita
que el pool se llene de jobIds que hace rato dejaron de estar vacíos.

El script degrada solo, en los dos sentidos: si el panel no está, no tiene el
fetcher prendido o el pool quedó vacío, `/api/fetch/server` contesta 503 y el
hop cae al listado directo de Roblox, exactamente como antes. Y si un jobId ya
se llenó entre el scrape y el salto, el teleport falla, el bot avisa por
`/api/fetch/drop` y ese server sale del pool en vez de repartirse a la siguiente
cuenta.

El panel lo muestra en **Pool de servers**: cuántos hay, cuántos quedan
disponibles, cuántos sin repartir, y los rate-limits y errores del scraper. Si
algo está mal configurado (sin proxies, o el scraper frenado por rate-limits) lo
dice ahí mismo con qué hacer al respecto.

Desde afuera del panel, con el token del bot: `GET /api/fetch/stats` para verlo,
`GET /api/fetch/recycle` para soltar las reservas ya vencidas y
`GET /api/fetch/clear` para tirar el pool entero sin esperar al wipe.

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
| GET | `/api/fetch/recycle` | Suelta a mano las reservas ya vencidas |
| GET | `/api/fetch/clear` | Tira el pool entero (sin esperar al wipe periódico) |

### Dashboard (cookie de sesión)

| Método | Ruta | Para qué |
|---|---|---|
| POST | `/api/auth/register` · `/login` · `/logout` | Sesión |
| GET | `/api/auth/me` | Usuario y token |
| POST | `/api/auth/token/rotate` | Token nuevo, el viejo muere |
| GET | `/api/overview?range=6h\|24h\|7d&tz=<min>` | Todo lo que pinta el panel, incluido el estado del pool de servers |
| POST | `/api/accounts/:id/command` | `enabled` `method` `speed` `autohop` `smart` `sweep` `hop` `waitevent` `antiafk` `optimizer` |
| DELETE | `/api/accounts/:id` | Quitar una cuenta y su historial |

### Admin (cookie de sesión, solo el primer usuario)

| Método | Ruta | Para qué |
|---|---|---|
| GET | `/api/admin/overview` | Usuarios, cuentas por usuario, cuántas vivas y cuántas corriendo, y el catálogo de scripts |
| POST | `/api/admin/users/:id/access` | `{approved: true\|false}` — da o saca el acceso al hub |
| POST | `/api/admin/users/:id/scripts` | `{script, allowed}` — habilita o corta UN script |

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
  Si se filtró, **Rotate token**.

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
  lib/scripts.js     catalogo de scripts y quien puede usar cada uno
  lib/limit.js       límite de requests por ventana deslizante, en memoria
  lib/roblox.js      miniaturas de avatar con caché de 6 h
  routes/admin.js    usuarios del hub y quién tiene acceso al loader
  routes/auth.js     registro, login, token
  routes/scripts.js  entrega los .lua, solo con token válido
  routes/bot.js      ingesta de telemetría y entrega de comandos
  routes/dash.js     el overview que consume el panel
  routes/fetch.js    API del fetcher: dispensa jobIds, acepta descartes
  fetcher/pool.js    el pool de servers: scrapers, reserva, reciclado
  fetcher/proxies.js parseo de proxies y borrado del id de sesión
  fetcher/http.js    GET con JSON a través del túnel del proxy
public/
  index.html         login y registro
  panel.html         el dashboard
  css/style.css      sistema visual (tema oscuro único, deliberado)
  js/charts.js       gráficos en SVG a mano, sin librerías
  js/panel.js        estado, render y polling
lua/                 (fuera de public/: no se sirven sin token ni sin permiso)
  honey_hub.lua      loader: descarga honey_tp.lua y lo arranca con (url, token)
  honey_tp.lua       el collector — movimiento, GUI, y el reporte a Railway integrado
  honey_merchant.lua el merchant — compra y sniper del BeeMerchantService, autocontenido
  PATCH.md           notas para quien venía de la versión con parche manual
```

### Sobre los colores

La paleta sale de la GUI del collector (ámbar `#ffab21` sobre ciruela oscuro)
para que la web y el panel del juego se lean como la misma cosa. Los colores de
dato están validados contra la superficie `#1b161c`: el ramp ámbar pasa
monotonía de luminosidad, salto mínimo entre pasos y contraste del extremo claro;
los cuatro colores de estado pasan 3:1. El estado **nunca** se comunica solo con
color — siempre va punto + texto. Si tocás un hex, volvé a validar la paleta.
