# 🍯 Honey Hub

Dashboard en vivo para el **Honey TP Collector**. Todas tus cuentas de Roblox
reportan a una misma pantalla: cuántos Honey Jars llevan en total, cuánto puso
cada una, a qué ritmo van, cuántos hops hicieron, en qué server están — y desde
ahí mismo las pausás, les cambiás el método o las hacés saltar de server.

**Cada usuario ve solo lo suyo.** Te registrás, recibís un token propio, y las
cuentas que usen ese token entran a *tu* panel. Dos personas pueden estar
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

### Correrlo local

```bash
cp .env.example .env      # apuntá DATABASE_URL a tu Postgres
npm install
npm start                 # http://localhost:3000
```

---

## Conectar una cuenta

En el panel, **＋ Conectar cuenta** te da el token y el snippet ya armado. Es
una sola línea, en el ejecutor:

```lua
loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua"))(
    "https://tu-app.up.railway.app", "hh_..."
)
```

`honey_hub.lua` es solo un loader: descarga el collector (`honey_tp.lua`) de la
misma URL y lo arranca con esos mismos dos argumentos. El reporte a Railway y
el control remoto ya vienen integrados en el collector — no hay un segundo
paso ni un parche que pegar a mano (ver [`lua/PATCH.md`](lua/PATCH.md) si
veniás de una versión anterior).

El mismo token va en **todas** tus cuentas: se separan solas por usuario de
Roblox. En unos segundos aparecen en el panel con su avatar y su contador,
honey (total y por cuenta), ritmo, ranking, racha, hops, server, uptime, y los
botones de control ya funcionando.

---

## Cómo funciona

### El conteo de jars

El jar **no se agarra tocándolo** — el evento lo crea con `CanTouch=false`. Quien
lo reclama es el cliente del juego cuando el `ProximityPrompt` se muestra, y ahí
dispara `EventService/Bee/ClaimHoney`. El hub escucha ese mismo remote y cuenta
cuando el jugador que se lo llevó sos vos. Por eso el número es el real y no una
estimación, y por eso incluye los jars que agarraste a mano.

### Los hops

No se cuentan en Lua: el teleport corta la ejecución antes de que el script
alcance a reportar el salto. El server los deriva viendo cambiar el `jobId` entre
un beat y el siguiente.

### Los totales

El script manda su contador **acumulado**, que arranca en 0 en cada corrida. El
server guarda el *delta* contra el beat anterior de esa misma sesión, así un
restart no se lee como una caída de 300 jars. Los deltas se acumulan en cubetas
de 5 minutos (`samples`), que es de donde salen el gráfico, la racha y la mejor
hora del día.

### Los comandos

El dashboard encola; el bot los levanta en su siguiente beat y los ackea cuando
los aplicó. Mientras tanto la tarjeta muestra *orden pendiente*. Un comando del
mismo tipo sin entregar queda obsoleto apenas llega otro: si tocaste velocidad
tres veces seguidas, al bot le llega la última.

---

## API

### Bot (`Authorization: Bearer <token>`)

| Método | Ruta | Para qué |
|---|---|---|
| POST | `/api/bot/hello` | Registra la corrida, cierra las sesiones viejas |
| POST | `/api/bot/beat` | Heartbeat: manda estado, recibe comandos |
| POST | `/api/bot/bye` | Cierre limpio (al salir o teleportar) |

### Dashboard (cookie de sesión)

| Método | Ruta | Para qué |
|---|---|---|
| POST | `/api/auth/register` · `/login` · `/logout` | Sesión |
| GET | `/api/auth/me` | Usuario y token |
| POST | `/api/auth/token/rotate` | Token nuevo, el viejo muere |
| GET | `/api/overview?range=6h\|24h\|7d&tz=<min>` | Todo lo que pinta el panel |
| POST | `/api/accounts/:id/command` | `enabled` `method` `speed` `autohop` `smart` `hop` |
| DELETE | `/api/accounts/:id` | Quitar una cuenta y su historial |

---

## Seguridad

- Contraseñas con bcrypt (12 rondas); sesión en cookie `httpOnly` + `sameSite`,
  y `secure` en producción.
- El `user_id` sale **siempre** de la cookie firmada, nunca del body. La
  pertenencia de una cuenta se chequea dentro del `WHERE` de la propia consulta,
  así no hay ventana entre verificar y escribir.
- Login con el mismo mensaje para usuario inexistente y contraseña incorrecta.
- Todos los valores que llegan del bot se recortan y se acotan antes de tocar la
  base; los comandos pasan por una lista blanca con validador por tipo.
- El token es lo único que separa un panel de otro: tratalo como una contraseña.
  Si se filtró, **Rotar token**.

---

## Estructura

```
src/
  server.js          arranque, estáticos, manejo de errores
  db.js              pool de Postgres + migración al arrancar
  schema.sql         esquema, idempotente
  lib/auth.js        bcrypt, JWT en cookie, requireUser
  lib/roblox.js      miniaturas de avatar con caché de 6 h
  routes/auth.js     registro, login, token
  routes/bot.js      ingesta de telemetría y entrega de comandos
  routes/dash.js     el overview que consume el panel
public/
  index.html         login y registro
  panel.html         el dashboard
  css/style.css      sistema visual (tema oscuro único, deliberado)
  js/charts.js       gráficos en SVG a mano, sin librerías
  js/panel.js        estado, render y polling
  honey_hub.lua      loader: descarga honey_tp.lua y lo arranca con (url, token)
  honey_tp.lua       el collector — movimiento, GUI, y el reporte a Railway integrado
lua/PATCH.md         notas para quien venía de la versión con parche manual
```

### Sobre los colores

La paleta sale de la GUI del collector (ámbar `#ffab21` sobre ciruela oscuro)
para que la web y el panel del juego se lean como la misma cosa. Los colores de
dato están validados contra la superficie `#1b161c`: el ramp ámbar pasa
monotonía de luminosidad, salto mínimo entre pasos y contraste del extremo claro;
los cuatro colores de estado pasan 3:1. El estado **nunca** se comunica solo con
color — siempre va punto + texto. Si tocás un hex, volvé a validar la paleta.
