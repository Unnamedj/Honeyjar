--[[
    HONEY HUB — loader
    ------------------------------------------------------------
    Punto de entrada unico: recibe la URL del panel y tu token, y con eso
    carga y ejecuta el collector completo (honey_tp.lua) pasandole los mismos
    dos argumentos. El reporte a Railway y el control remoto ya viven adentro
    del collector -- no hay un segundo paso ni un parche que pegar a mano.

        loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua"))(
            "https://tu-app.up.railway.app", "hh_..."
        )

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
    warn("[HONEY HUB] falta URL o token — pasalos como argumentos: loadstring(...)(url, token)")
    return
end

local ok, chunkOrErr = pcall(game.HttpGet, game, BASE_URL .. "/honey_tp.lua")
if not ok then
    warn("[HONEY HUB] no pude descargar el collector — " .. tostring(chunkOrErr))
    return
end

local collector, compileErr = loadstring(chunkOrErr)
if not collector then
    warn("[HONEY HUB] el collector no compilo — " .. tostring(compileErr))
    return
end

local ranOk, runErr = pcall(collector, BASE_URL, TOKEN)
if not ranOk then
    warn("[HONEY HUB] el collector fallo al arrancar — " .. tostring(runErr))
end
