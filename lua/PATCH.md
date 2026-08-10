# Conectar el collector al Honey Hub

**Ya no hace falta ningun parche manual.** Esto se cerro sobre `honey_hub.lua`
y `honey_tp.lua`, que ahora vienen integrados: `honey_hub.lua` es un loader de
una linea, y `honey_tp.lua` (el collector) trae el reporte a Railway y el
control remoto ya incorporados, activos solo si recibio URL y token.

## Uso

Un solo `loadstring`, en el ejecutor:

```lua
loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua"))(
    "https://tu-app.up.railway.app", "hh_tu_token"
)
```

El token sale del panel, en **＋ Conectar cuenta**. El mismo token va en todas
tus cuentas: se separan solas por usuario de Roblox.

Eso es todo. `honey_hub.lua` descarga `honey_tp.lua` desde la misma URL y lo
arranca pasandole `(BASE_URL, TOKEN)`. El collector:

- Corre normal, con su GUI y toda la logica de movimiento, igual que siempre.
- Si recibio URL y token, reporta a Railway (`hello` al arrancar, `beat` cada
  pocos segundos, `bye` al cerrar o teletransportar) y aplica los comandos que
  lleguen del panel (pausar, cambiar metodo, velocidad, hop ya).
- Si se ejecuta **sin** argumentos (pegando `honey_tp.lua` directo, sin pasar
  por `honey_hub.lua`), corre igual pero no reporta nada — sigue siendo un
  collector standalone.

## Si algo no anda

- **La cuenta no aparece.** Fijate en la consola del ejecutor. `falta URL o
  token` es que no se pasaron como argumentos del `loadstring(...)(url,
  token)`; `no pude registrarme` es que están pero uno de los dos está mal.
- **El collector no arranca.** `no pude descargar el collector` o `el
  collector no compilo` apuntan a la URL: confirma que `honey_tp.lua` esta
  desplegado en el mismo dominio que pasaste.
- **La cuenta figura offline con el juego abierto.** El ejecutor no tiene
  `request`/`http_request`. Sin POST no hay telemetría posible, pero el
  collector sigue funcionando igual.
