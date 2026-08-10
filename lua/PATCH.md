# Conectar el collector al Honey Hub

El cliente (`honey_hub.lua`) **funciona sin tocar nada**: cuenta los jars
escuchando el mismo remote que usa el juego (`EventService/Bee/ClaimHoney`), y
los hops los deriva el server viendo cambiar el `jobId`. Con eso solo, el panel
ya muestra honey total, por cuenta, ritmo, ranking, racha, server y uptime.

Lo que **no** se puede saber desde afuera es el estado interno del collector
(`Auto Collect` prendido, método, velocidad) ni aplicarle órdenes. Para eso hace
falta este parche: un solo bloque al final del script.

---

## Paso 1 — pegá las dos líneas del hub antes del collector

```lua
getgenv().HONEY_HUB_URL   = "https://tu-app.up.railway.app"
getgenv().HONEY_HUB_TOKEN = "hh_tu_token"
loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua"))()
```

El token sale del panel, en **＋ Conectar cuenta**. El mismo token va en todas
tus cuentas: se separan solas por usuario de Roblox.

## Paso 2 — pegá este bloque al FINAL del collector

Al final del todo, después del `print("[HONEY TP] method: ...")`. Tiene que ir
ahí y no antes: usa `SetState`, `PaintMethods`, `FindSmallServer` y compañía, que
recién existen a esa altura del archivo.

```lua
-- ============================================================
-- HONEY HUB BRIDGE
-- ------------------------------------------------------------
-- Publica el estado del collector y expone como aplicarle ordenes. El cliente
-- del hub lo detecta solo; si este bloque no esta, el hub reporta igual pero
-- sin control remoto.
-- ============================================================
do
    local Hub = (getgenv and getgenv()) or _G

    local Bridge = {
        honey      = 0,
        status     = "Idle",
        statusKind = "idle",
        config     = Config,   -- referencia viva: el panel lee Method/Speed/Enabled de aca
    }
    Hub.HoneyHubBridge = Bridge

    -- El contador vive en un local del collector, asi que se espeja cada
    -- segundo en vez de exponerlo (es la unica forma sin reescribir el resto).
    task.spawn(function()
        while ScreenGui.Parent do
            Bridge.honey = Collected
            task.wait(1)
        end
    end)

    -- SetStatus ya existe y lo llaman todos los loops. Envolverlo es lo que
    -- hace que el panel muestre el MISMO texto que la GUI del juego, en vez de
    -- una adivinanza.
    local RawSetStatus = SetStatus
    SetStatus = function(Text, Color)
        Bridge.status = Text
        local Lower = tostring(Text):lower()
        if Lower:find("collecting") then
            Bridge.statusKind = "collecting"
        elseif Lower:find("hop") or Lower:find("server chico") then
            Bridge.statusKind = "hopping"
        elseif Lower:find("waiting") then
            Bridge.statusKind = "waiting"
        elseif Lower:find("stopped") then
            Bridge.statusKind = "stopped"
        else
            Bridge.statusKind = Config.Enabled and "waiting" or "idle"
        end
        return RawSetStatus(Text, Color)
    end

    function Bridge.apply(Kind, Value)
        if Kind == "enabled" then
            SetState(Value == "on")

        elseif Kind == "method" then
            Config.Method = Value
            SaveConfig()
            PaintMethods()
            -- Mismo gesto que el boton de la GUI: cortar el viaje en curso para
            -- que el metodo nuevo se use ya, no recien en el proximo jar.
            Cancel = true
            task.delay(0.1, function() Cancel = false end)

        elseif Kind == "speed" then
            Config.Speed = math.clamp(tonumber(Value) or Config.Speed, 50, 1000)
            SaveConfig()
            SyncSpeedDisplay()

        elseif Kind == "autohop" then
            Config.AutoHop = (Value == "on")
            SaveConfig()
            PaintHop()

        elseif Kind == "smart" then
            Config.SmartTP = (Value == "on")
            SaveConfig()
            PaintSmart()

        elseif Kind == "hop" then
            -- HopToSmallServer loopea mientras AutoHop este prendido; para un
            -- salto puntual se llama directo al buscador y se teleporta una vez.
            task.spawn(function()
                SetStatus("Hop manual desde el panel...", COLORS.bad)
                local Server = FindSmallServer()
                if Server then
                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(TARGET_PLACE_ID, Server.id, LocalPlayer)
                    end)
                else
                    pcall(function() TeleportService:Teleport(TARGET_PLACE_ID, LocalPlayer) end)
                end
            end)
        end
    end
end
```

## Paso 3 — listo

Ejecutá el collector como siempre. En el panel la cuenta pasa de mostrar
`Sin puente` a mostrar el estado real, y los botones de cada tarjeta empiezan a
funcionar.

---

## Qué habilita cada cosa

| Dato / acción | Sin parche | Con parche |
|---|---|---|
| Honey total y por cuenta | ✅ (remote `ClaimHoney`) | ✅ |
| Ritmo, ranking, racha, podio | ✅ | ✅ |
| Server actual, jugadores, uptime | ✅ | ✅ |
| Hops | ✅ (cambio de `jobId`) | ✅ |
| Estado exacto del collector | ❌ (se infiere) | ✅ |
| Método / velocidad / AutoHop / Smart | ❌ | ✅ |
| Pausar y reanudar desde la web | ❌ | ✅ |
| Cambiar método o velocidad desde la web | ❌ | ✅ |
| Hop ya | ❌ | ✅ |

## Si algo no anda

- **La cuenta no aparece.** Fijate en la consola del ejecutor. `[HONEY HUB] falta
  HONEY_HUB_URL o HONEY_HUB_TOKEN` es que las dos líneas quedaron después del
  `loadstring`; `no pude registrarme` es URL o token mal.
- **Aparece pero el honey queda en 0.** El enganche a `ClaimHoney` falló (la
  carpeta `Packages` todavía cargaba). Reintenta 12 veces cada 5 s; si igual no
  entra, aplicá el parche y el contador sale del collector.
- **Los botones dicen "orden pendiente" y no pasa nada.** Falta el bloque del
  paso 2, o quedó pegado antes del final del script.
- **La cuenta figura offline con el juego abierto.** El ejecutor no tiene
  `request`/`http_request`. Sin POST no hay telemetría posible.
