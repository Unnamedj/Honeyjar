--[[
    HONEY HUB — cliente de telemetria
    ------------------------------------------------------------
    Reporta esta cuenta al panel web y aplica los comandos que llegan desde ahi.

    Uso (antes del collector) — URL y token van como argumentos al chunk, no
    como variables globales:

        loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_hub.lua"))(
            "https://tu-app.up.railway.app", "hh_..."
        )

    Funciona SOLO, sin tocar el collector: cuenta los jars escuchando el mismo
    remote que usa el juego para reclamarlos (EventService/Bee/ClaimHoney), asi
    que el numero es el real, no una estimacion.

    Los hops NO se cuentan aca: el teleport corta la ejecucion antes de que un
    contador en Lua alcance a reportarse, asi que los deriva el server viendo
    cambiar el jobId entre beats.

    Si ademas aplicas el patch de lua/PATCH.md, el collector publica su estado en
    getgenv().HoneyHubBridge y con eso se habilita lo que no se puede deducir
    desde afuera: estado exacto, config en vivo, y el control remoto (pausar,
    cambiar metodo, velocidad, hop ya).
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- URL y token llegan como argumentos del loadstring, no por variable global.
local BASE_URL, TOKEN = ...
BASE_URL = tostring(BASE_URL or ""):gsub("/+$", "")
TOKEN    = tostring(TOKEN or "")

if BASE_URL == "" or TOKEN == "" then
    warn("[HONEY HUB] falta URL o token — pasalos como argumentos: loadstring(...)(url, token)")
    return
end

local G = (getgenv and getgenv()) or _G

-- Solo una instancia viva. Si el script se ejecuta de nuevo (o el collector se
-- recarga), el token nuevo invalida el loop anterior sin dejar dos reportando.
G.__HoneyHubRun = (G.__HoneyHubRun or 0) + 1
local MyToken = G.__HoneyHubRun

-- ============================================================
-- HTTP
-- ============================================================
-- Cada ejecutor expone el POST con otro nombre. Se resuelve una vez.
local HttpPost do
    local impl = (syn and syn.request)
        or (http and http.request)
        or http_request
        or request
        or (fluxus and fluxus.request)

    if type(impl) ~= "function" then
        warn("[HONEY HUB] tu ejecutor no expone request/http_request — no puedo reportar")
        return
    end

    function HttpPost(path, body)
        local ok, res = pcall(impl, {
            Url = BASE_URL .. path,
            Method = "POST",
            Headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. TOKEN,
            },
            Body = HttpService:JSONEncode(body),
        })
        if not ok or type(res) ~= "table" then return nil end
        if (res.StatusCode or res.status_code or 0) >= 400 then
            return nil, res.StatusCode or res.status_code
        end

        local decoded
        local decodeOk = pcall(function()
            decoded = HttpService:JSONDecode(res.Body or res.body or "{}")
        end)
        return decodeOk and decoded or nil
    end
end

-- ============================================================
-- PUENTE CON EL COLLECTOR (opcional)
-- ============================================================
-- El collector parcheado publica aca su estado y su forma de aplicar comandos.
-- Todo lo que sigue trata al puente como "puede no existir": sin el, el hub
-- reporta igual, solo que con menos detalle y sin control remoto.
local function Bridge()
    local b = G.HoneyHubBridge
    return type(b) == "table" and b or nil
end

-- ============================================================
-- CONTEO DE JARS (sin depender del collector)
-- ============================================================
-- El juego reclama el jar disparando EventService/Bee/ClaimHoney y despues
-- avisa a todos los clientes con el jugador que se lo llevo. Escuchar ese
-- OnClientEvent y filtrar por LocalPlayer da el conteo exacto, incluidos los
-- jars que agarraste a mano.
local Honey = 0
local HoneyHooked = false

local function HookHoneyCounter()
    if HoneyHooked then return true end

    local ok, remote = pcall(function()
        local packages = ReplicatedStorage:WaitForChild("Packages", 10)
        local net = packages and packages:WaitForChild("Net", 10)
        local module = net and net:FindFirstChildWhichIsA("ModuleScript", true)
        if not module then return nil end
        return require(module):RemoteEvent("EventService/Bee/ClaimHoney")
    end)

    if not ok or typeof(remote) ~= "Instance" then return false end

    remote.OnClientEvent:Connect(function(_, player)
        if player == LocalPlayer then
            Honey = Honey + 1
        end
    end)

    HoneyHooked = true
    return true
end

task.spawn(function()
    -- La carpeta Packages puede seguir llegando por streaming al arrancar.
    for _ = 1, 12 do
        if HookHoneyCounter() then return end
        task.wait(5)
    end
    warn("[HONEY HUB] no pude enganchar ClaimHoney; uso el contador del collector si existe")
end)

-- ============================================================
-- ESTADO REPORTADO
-- ============================================================
local function ReadHoney()
    local bridge = Bridge()
    -- El contador propio es el de referencia; el del collector solo entra si el
    -- enganche al remote fallo, para no perder el dato del todo.
    if HoneyHooked then return Honey end
    if bridge and type(bridge.honey) == "number" then return bridge.honey end
    return Honey
end

-- Traduce el texto de estado del collector a una de las categorias que el panel
-- pinta. Si el puente ya trae statusKind, se respeta.
local function ClassifyStatus(text, enabled)
    if type(text) == "string" then
        local lower = text:lower()
        if lower:find("collecting") then return "collecting" end
        if lower:find("hop") or lower:find("server chico") then return "hopping" end
        if lower:find("waiting") or lower:find("esperando") then return "waiting" end
        if lower:find("stopped") then return "stopped" end
    end
    return enabled and "waiting" or "idle"
end

local function Snapshot()
    local bridge = Bridge()
    local config = bridge and type(bridge.config) == "table" and bridge.config or nil

    local status = bridge and bridge.status or (HoneyHooked and "Reportando" or "Sin puente")
    local enabled = config and config.Enabled or false

    return {
        token   = TOKEN,
        client  = G.__HoneyHubClientId,
        roblox  = {
            id      = LocalPlayer.UserId,
            name    = LocalPlayer.Name,
            display = LocalPlayer.DisplayName,
        },
        honey      = ReadHoney(),
        status     = status,
        statusKind = (bridge and bridge.statusKind) or ClassifyStatus(status, enabled),
        method     = config and config.Method or nil,
        speed      = config and config.Speed or nil,
        autoHop    = config and config.AutoHop or false,
        smartTP    = config and config.SmartTP or false,
        enabled    = enabled,
        jobId      = game.JobId,
        placeId    = game.PlaceId,
        players    = #Players:GetPlayers(),
    }
end

-- ============================================================
-- COMANDOS
-- ============================================================
local Acked = {}

local function ApplyCommand(command)
    local bridge = Bridge()
    if not bridge or type(bridge.apply) ~= "function" then
        -- Sin puente no hay como tocar el collector. Se ackea igual para que el
        -- panel no muestre la orden colgada para siempre.
        return false
    end

    local ok, err = pcall(bridge.apply, command.kind, command.value)
    if not ok then
        warn("[HONEY HUB] comando '" .. tostring(command.kind) .. "' fallo: " .. tostring(err))
    end
    return ok
end

local function HandleCommands(list)
    if type(list) ~= "table" then return end
    for _, command in ipairs(list) do
        if type(command) == "table" and command.id then
            ApplyCommand(command)
            table.insert(Acked, command.id)
        end
    end
end

-- ============================================================
-- LOOP
-- ============================================================
G.__HoneyHubClientId = HttpService:GenerateGUID(false)

local BeatMs = 5000

task.spawn(function()
    local hello = HttpPost("/api/bot/hello", Snapshot())
    if not hello then
        warn("[HONEY HUB] no pude registrarme — revisa la URL y el token")
        return
    end
    if type(hello.beatMs) == "number" then BeatMs = hello.beatMs end
    HandleCommands(hello.commands)

    print(("[HONEY HUB] conectado como %s · beat %dms"):format(LocalPlayer.Name, BeatMs))

    while MyToken == G.__HoneyHubRun do
        local payload = Snapshot()
        if #Acked > 0 then
            payload.ack = Acked
            Acked = {}
        end

        local res = HttpPost("/api/bot/beat", payload)
        if res then
            if type(res.beatMs) == "number" then BeatMs = res.beatMs end
            HandleCommands(res.commands)
        end

        task.wait(BeatMs / 1000)
    end
end)

-- Aviso de cierre: sin esto la cuenta queda "online" en el panel hasta que
-- vence la ventana de 45s.
game:BindToClose(function()
    pcall(HttpPost, "/api/bot/bye", { token = TOKEN, client = G.__HoneyHubClientId })
end)

LocalPlayer.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started then
        pcall(HttpPost, "/api/bot/bye", { token = TOKEN, client = G.__HoneyHubClientId })
    end
end)
