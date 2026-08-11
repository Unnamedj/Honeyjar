--[[
    HONEY HUB — loader
    ------------------------------------------------------------
    Punto de entrada unico: recibe la URL del panel y tu token, y con eso
    carga y ejecuta el collector completo (honey_tp.lua) pasandole los mismos
    dos argumentos. El reporte a Railway y el control remoto ya viven adentro
    del collector -- no hay un segundo paso ni un parche que pegar a mano.

        loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua?token=hh_..."))(
            "https://tu-app.up.railway.app", "hh_..."
        )

    El token va tambien en la URL porque el server no entrega el .lua sin el:
    game:HttpGet no manda headers, asi que la query es el unico lugar donde
    puede viajar.

    El mismo token va en todas tus cuentas: se separan solas por usuario de
    Roblox (ver /api/bot/hello en el server). Si el ejecutor no expone
    request/http_request, el collector igual corre -- solo que sin reportar.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local BASE_URL, TOKEN = ...
BASE_URL = tostring(BASE_URL or ""):gsub("/+$", "")
TOKEN    = tostring(TOKEN or "")

if BASE_URL == "" or TOKEN == "" then
    warn("[HONEY HUB] missing URL or token — pass them as arguments: loadstring(...)(url, token)")
    return
end

-- El collector tampoco es publico: va el mismo token que ya tenemos.
local url = BASE_URL .. "/honey_tp.lua?token=" .. game:GetService("HttpService"):UrlEncode(TOKEN)

local ok, chunkOrErr = pcall(game.HttpGet, game, url)
if not ok then
    warn("[HONEY HUB] could not download the collector — " .. tostring(chunkOrErr))
    return
end

-- El server contesta un comentario de Lua cuando el token no sirve: compila
-- igual (no hace nada) y el usuario se queda sin saber por que. Mejor decirlo.
if chunkOrErr:match("^%-%- Honey Hub:") then
    warn("[HONEY HUB] " .. chunkOrErr:gsub("^%-%-%s*Honey Hub:%s*", ""):gsub("%s+$", ""))
    return
end

local collector, compileErr = loadstring(chunkOrErr)
if not collector then
    warn("[HONEY HUB] the collector did not compile — " .. tostring(compileErr))
    return
end

local ranOk, runErr = pcall(collector, BASE_URL, TOKEN)
if not ranOk then
    warn("[HONEY HUB] the collector failed to start — " .. tostring(runErr))
end
