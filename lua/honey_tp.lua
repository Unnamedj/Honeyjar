--[[
    HONEY TP COLLECTOR
    ------------------------------------------------------------
    Escanea los Honey Jar del evento Bee y va por ellos usando las mismas
    logicas de movimiento del hub en vez de caminar con Humanoid:MoveTo.

    La jarra no se toca: el evento la crea con CanTouch=false, y quien la
    reclama es el cliente del juego cuando su ProximityPrompt se muestra
    (12 studs). Por eso el collector llega y espera ahi.

    Metodos disponibles:
      Grapple - dispara el Grapple Hook por el remote UseItem para despegar
                y recien ahi monta la carpet (el mas fiel al hub de referencia)
      Carpet  - monta la carpet directo, sin el tiron del gancho

    Reporte a Honey Hub (Railway) -- OPCIONAL Y AUTOMATICO:
    Si este script se carga con (BASE_URL, TOKEN) como argumentos del
    loadstring, al final reporta solo, sin pasos extra:

        loadstring(game:HttpGet("https://tu-app.up.railway.app/honey_tp.lua"))(
            "https://tu-app.up.railway.app", "hh_..."
        )

    Sin argumentos corre igual, standalone, sin reportar nada. La forma mas
    simple de usarlo con reporte es via honey_hub.lua, que es solo un loader
    de una linea que pasa estos mismos dos argumentos.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Workspace          = game:GetService("Workspace")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Players            = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local TeleportService  = game:GetService("TeleportService")
local HttpService      = game:GetService("HttpService")
local CoreGui          = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local G = (getgenv and getgenv()) or _G
G.__HoneyTPRun = (G.__HoneyTPRun or 0) + 1
local MyToken  = G.__HoneyTPRun

local TARGET_PLACE_ID = 109983668079237
local CONFIG_FILE     = "honey_tp.json"

-- URL y token del Honey Hub, si llegaron como argumentos del loadstring. Son
-- opcionales: sin ellos el collector corre igual, solo que no reporta nada.
local HubBaseUrl, HubToken = ...
HubBaseUrl = tostring(HubBaseUrl or ""):gsub("/+$", "")
HubToken   = tostring(HubToken or "")

-- Puente hacia el FETCHER del panel (pool de servers frescos scrapeados con
-- proxies rotativos). Es UNA sola tabla y no varios locals sueltos a proposito:
-- el chunk esta al filo del limite de 200 variables locales de Lua, asi que
-- todo lo del fetcher viaja como campos (Hop.Take, Hop.Drop, Hop.Pick, ...)
-- que no cuentan para ese limite.
--
-- Se declara aca arriba porque el hop -- que vive mucho antes en el archivo --
-- la usa, pero Take/Drop recien se asignan al final, dentro del bloque de Hub
-- reporting, que es el unico que sabe hablar HTTP autenticado. Si el script
-- corre standalone (sin URL/token) quedan en nil y el hop se comporta
-- exactamente como antes: pagina games.roblox.com por su cuenta.
local Hop = {}

-- Tracker del evento Bee. Sin evento no hay jarras que juntar, asi que el
-- collector no tiene por que estar escaneando ni gastando hops: con
-- Config.WaitEvent prendido se queda quieto hasta que arranca. Se declara aca
-- arriba porque el loop del collector -- que vive mucho antes que la GUI -- lo
-- consulta; los metodos se asignan mas abajo, cuando ya existe ScanHoney.
--
-- `Models` indexa las abejas del evento que hay en el mapa; se llena desde la
-- misma conexion de Workspace que indexa las jarras (ver TrackCandidate).
local Bee = { Active = false, Source = "-", CheckedAt = 0, Models = { } }

-- Optimizer (menos VFX = mas FPS con varias cuentas abiertas) y el HUD nuevo.
-- Los dos se arman al final, con la GUI, pero se declaran aca por lo mismo.
local Boost = {}
local HUD = {}

-- Puente para llamar codigo del juego sin que se note que la llamada viene de
-- afuera. Se llena justo abajo. Ver el bloque ENV LEAK.
local Env = {}

-- ============================================================
-- ENV LEAK -- llamar al juego sin que la llamada se vea de afuera
-- ------------------------------------------------------------
-- Portado de honeymerchant.lua, que usa esta misma capa para requerir modulos
-- del juego (Net incluido) sin comerse un kick.
--
-- El problema no es require() en si: es DESDE DONDE se lo llama. Una llamada
-- cruda desde el ejecutor se delata por tres lados a la vez:
--
--   · el `require` del ejecutor suele venir envuelto y no pega en la cache
--     real de Roblox, asi que RE-EJECUTA el modulo -- y con EventController eso
--     significa levantar un segundo ReplicatorClient hablandole al server;
--   · la identidad del hilo es la elevada del ejecutor (7/8), no la 2 de un
--     LocalScript;
--   · arriba de la llamada quedan nuestros frames, con el chunk name del
--     loadstring, y un getfenv(nivel) desde el modulo los encuentra.
--
-- Env arma un espejo contra las tres: usa el require REAL del juego (que si
-- pega en la cache y devuelve la MISMA tabla que ya tiene el cliente, sin
-- re-ejecutar nada), presta el entorno de un LocalScript vivo, baja la
-- identidad mientras dura la llamada, y hace nacer la llamada en un hilo
-- aparte para que arriba del trampolin no haya un solo frame nuestro.
--
-- Todo best-effort: si el ejecutor no trae getrenv/getsenv/setfenv/
-- setthreadidentity, cada capa se cae sola y el resto sigue andando.
do
    local GAME_IDENTITY = 2   -- la de un LocalScript
    local CALL_TIMEOUT = 10

    local RealEnv
    pcall(function()
        if type(getrenv) == "function" then RealEnv = getrenv() end
    end)
    if type(RealEnv) ~= "table" then RealEnv = nil end

    -- El require del juego, no el del ejecutor: es el que usa la cache real.
    local RealRequire = (RealEnv and rawget(RealEnv, "require")) or require

    -- getsenv solo sirve con scripts que esten corriendo, y de afuera no hay
    -- forma de saber cuales: se juntan candidatos y se prueban de a uno.
    local Candidates, Seen = { }, { }
    local function Absorb(Pool)
        for _, Obj in ipairs(Pool) do
            if #Candidates >= 12 then return end
            local OK, IsLocal = pcall(function() return Obj:IsA("LocalScript") end)
            if OK and IsLocal and not Seen[Obj] then
                Seen[Obj] = true
                table.insert(Candidates, Obj)
            end
        end
    end
    pcall(function()
        if type(getrunningscripts) == "function" then Absorb(getrunningscripts()) end
    end)
    pcall(function()
        local PS = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
        if PS then Absorb(PS:GetDescendants()) end
    end)
    pcall(function() Absorb(PlayerGui:GetDescendants()) end)

    local Host = Candidates[1]
    local Mirror, MirrorKind = nil, "ninguno"

    -- Lo mejor: el entorno literal de un script del juego. Indistinguible
    -- porque no es una imitacion, es uno de verdad.
    if type(getsenv) == "function" then
        for _, Script_ in ipairs(Candidates) do
            local OK, Cand = pcall(getsenv, Script_)
            if OK and type(Cand) == "table" then
                Host, Mirror, MirrorKind = Script_, Cand, "prestado"
                break
            end
        end
    end

    -- Respaldo: un entorno de LocalScript es exactamente esto -- una tabla con
    -- `script` adentro y __index a las globales reales.
    if not Mirror and RealEnv then
        if Host then
            Mirror, MirrorKind = setmetatable({ script = Host }, { __index = RealEnv }), "imitado"
        else
            Mirror, MirrorKind = RealEnv, "globales"
        end
    end

    -- El trampolin: el unico frame Lua entre nosotros y el juego. Su entorno es
    -- el espejo, asi que un getfenv que suba desde el modulo aterriza aca y ve
    -- un LocalScript.
    local Invoke = function(Fn, ...) return Fn(...) end

    -- El cuerpo del hilo tambien es un frame sobre el juego, asi que lleva el
    -- mismo entorno. Pack/Protect van como upvalues: setfenv no los toca, asi
    -- el espejo puede ser cualquier cosa sin romper esto.
    local Pack, Protect = table.pack, pcall
    local Runner = function(Slot, Fn, ...)
        Slot.Output = Pack(Protect(Invoke, Fn, ...))
        Slot.Finished = true
    end

    local FenvOK = false
    if type(setfenv) == "function" and type(Mirror) == "table" then
        FenvOK = pcall(setfenv, Invoke, Mirror) and true or false
        if FenvOK then pcall(setfenv, Runner, Mirror) end
    end

    local GetId, SetId
    do
        local function Pick(Getter, Setter)
            if type(Getter) == "function" and type(Setter) == "function" then
                GetId, SetId = Getter, Setter
                return true
            end
            return false
        end
        local Syn = (type(syn) == "table") and syn or nil
        local _ = Pick(getthreadidentity, setthreadidentity)
            or Pick(getidentity, setidentity)
            or Pick(get_thread_identity, set_thread_identity)
            or (Syn ~= nil and Pick(Syn.get_thread_identity, Syn.set_thread_identity))
    end
    local IdOK = (GetId ~= nil and SetId ~= nil)

    --- Corre Fn como si fuera un LocalScript del juego. Devuelve igual que
    --- pcall: OK, resultados...
    function Env.Call(Fn, ...)
        -- Solo se baja la identidad si primero se pudo leer la vieja: si no, no
        -- habria con que volver y el hilo se quedaria en 2 para siempre, sin
        -- los privilegios del ejecutor.
        local Previous
        if IdOK then
            local ReadOK = pcall(function() Previous = GetId() end)
            if ReadOK and Previous ~= nil then
                pcall(SetId, GAME_IDENTITY)
            else
                Previous = nil
            end
        end

        -- El hilo nace con la identidad ya bajada: la hereda. Y como el modulo
        -- puede ceder (WaitForChild, InvokeServer) se espera a que muera en vez
        -- de confiar en lo que devuelve el resume; si no cede, el resume corre
        -- entero de una y no se pierde ni un frame.
        local Slot = { Finished = false }
        local Thread = coroutine.create(Runner)
        coroutine.resume(Thread, Slot, Fn, ...)

        local Deadline = os.clock() + CALL_TIMEOUT
        while not Slot.Finished and os.clock() < Deadline do
            RunService.Heartbeat:Wait()
        end

        if Previous ~= nil then pcall(SetId, Previous) end

        if not Slot.Finished then return false, "la llamada al juego no respondio" end
        return table.unpack(Slot.Output, 1, Slot.Output.n)
    end

    --- require de un modulo del juego. Cachear no es solo velocidad: cada
    --- require repetido es otro cruce hacia el juego.
    local ModuleCache = { }
    function Env.Require(Module)
        local Cached = ModuleCache[Module]
        if Cached ~= nil then return true, Cached end
        local OK, Result = Env.Call(RealRequire, Module)
        if OK then ModuleCache[Module] = Result end
        return OK, Result
    end

    -- Lo que de verdad evita el kick no es fenv ni la identidad -- esas dos
    -- capas solo tapan que la llamada vino de afuera si algo camina la pila.
    -- Lo que evita el kick es que RealRequire sea el require DEL JUEGO (el que
    -- pega en su cache real) y no el del ejecutor (que re-ejecuta el modulo).
    -- Eso depende de una sola cosa: que getrenv() haya funcionado. Si el
    -- ejecutor no lo trae, RealRequire cae en silencio al require de siempre
    -- (linea de arriba: "or require") y Env.Require deja de estar protegido --
    -- pero seguia llamandose igual, como si lo estuviera. Eso es lo que
    -- explica un kick que sobrevive al parche: no fallaba la logica, fallaba
    -- una asuncion que nada verificaba.
    --
    -- Env.Safe es esa verificacion. Bee.Controller y Grapple.Refs la miran
    -- ANTES de llamar a Env.Require sobre un modulo del juego: sin ella, ni
    -- lo intentan.
    Env.Safe = (RealEnv ~= nil)

    Env.Report = {
        Mirror = MirrorKind,
        Host = Host and Host.Name or nil,
        Fenv = FenvOK,
        Identity = IdOK,
        RealRequire = Env.Safe,
    }

    print(
        ("[HONEY TP] Env: mirror=%s realRequire=%s fenv=%s identity=%s%s"):format(
            MirrorKind, tostring(Env.Safe), tostring(FenvOK), tostring(IdOK),
            Env.Safe and "" or "  -- SIN getrenv: EventController y el mouse del gancho quedan en modo pasivo"
        )
    )
end

-- ============================================================
-- CONFIG
-- ============================================================
local Config = {
    Method = "Grapple",
    Speed = 280,
    Climb = 200,
    HealthLock = false,
    AutoHop = false,
    SmartTP = false,
    Enabled = false,
    -- Velocidad de Carpet cuando Smart TP cae a Carpet (gancho en cooldown):
    -- configurable, se guarda y se lee igual que el resto de Config.
    SmartFallbackSpeed = 250,
    -- Orden en que se visitan las jarras del lote (ver la tabla Route):
    -- prendido = barrido angular planeado de una (un solo trazo), apagado =
    -- la mas cercana recalculada en cada paso (el comportamiento historico).
    SweepRoute = true,
    -- Esperar a que el evento Bee este activo antes de juntar o hopear.
    WaitEvent = true,
    -- Responder al aviso de inactividad de Roblox para no comerse el kick.
    AntiAfk = true,
    -- Apagar VFX del mapa para ganar FPS. Arranca apagado a proposito: toca
    -- el juego de verdad y se prende cuando el usuario quiere, no de prepo.
    Optimizer = false,
}

if readfile and isfile and isfile(CONFIG_FILE) then
    pcall(function()
        local Data = HttpService:JSONDecode(readfile(CONFIG_FILE))
        if type(Data) == "table" then
            if Data.Method == "Grapple" or Data.Method == "Carpet" then
                Config.Method = Data.Method
            end
            local Speed = tonumber(Data.Speed)
            if Speed then Config.Speed = math.clamp(Speed, 50, 1000) end
            local Climb = tonumber(Data.Climb)
            if Climb then Config.Climb = math.clamp(Climb, 50, 600) end
            if type(Data.HealthLock) == "boolean" then Config.HealthLock = Data.HealthLock end
            if type(Data.AutoHop) == "boolean" then Config.AutoHop = Data.AutoHop end
            if type(Data.SmartTP) == "boolean" then Config.SmartTP = Data.SmartTP end
            if type(Data.Enabled) == "boolean" then Config.Enabled = Data.Enabled end
            local FallbackSpeed = tonumber(Data.SmartFallbackSpeed)
            if FallbackSpeed then Config.SmartFallbackSpeed = math.clamp(FallbackSpeed, 50, 1000) end
            if type(Data.SweepRoute) == "boolean" then Config.SweepRoute = Data.SweepRoute end
            if type(Data.WaitEvent) == "boolean" then Config.WaitEvent = Data.WaitEvent end
            if type(Data.AntiAfk) == "boolean" then Config.AntiAfk = Data.AntiAfk end
            if type(Data.Optimizer) == "boolean" then Config.Optimizer = Data.Optimizer end
        end
    end)
end

local function SaveConfig()
    if not writefile then return end
    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode({
            Method = Config.Method,
            Speed = Config.Speed,
            Climb = Config.Climb,
            HealthLock = Config.HealthLock,
            AutoHop = Config.AutoHop,
            SmartTP = Config.SmartTP,
            Enabled = Config.Enabled,
            SmartFallbackSpeed = Config.SmartFallbackSpeed,
            SweepRoute = Config.SweepRoute,
            WaitEvent = Config.WaitEvent,
            AntiAfk = Config.AntiAfk,
            Optimizer = Config.Optimizer,
        }))
    end)
end

-- ============================================================
-- HELPERS
-- ============================================================
local function GetRoot()
    local Char = LocalPlayer.Character
    return Char and (Char:FindFirstChild("HumanoidRootPart") or Char:FindFirstChild("UpperTorso"))
end

local function GetHumanoid()
    local Char = LocalPlayer.Character
    return Char and Char:FindFirstChildOfClass("Humanoid")
end

local function FindTool(Name)
    local Char = LocalPlayer.Character
    local Backpack = LocalPlayer:FindFirstChild("Backpack")
    if Char then
        local T = Char:FindFirstChild(Name)
        if T and T:IsA("Tool") then return T end
    end
    if Backpack then
        local T = Backpack:FindFirstChild(Name)
        if T and T:IsA("Tool") then return T end
    end
    return nil
end

-- ============================================================
-- TP CORE  (portado del hub)
-- ============================================================
local Cancel = false

local CARPET_NAMES = {
    "Flying Carpet", "Carpet", "Cloud", "Witch's Broom",
    "Cupid's Wings", "Santa's Sleigh", "Magic Carpet",
}

local function EquipCarpet()
    local Char = LocalPlayer.Character
    local Humanoid = Char and Char:FindFirstChildOfClass("Humanoid")
    if not Humanoid then return nil end
    for _, Name in ipairs(CARPET_NAMES) do
        local T = FindTool(Name)
        if T and T:IsA("Tool") then
            if T.Parent ~= Char then pcall(function() Humanoid:EquipTool(T) end) end
            return Name
        end
    end
    return nil
end

-- El resolver del remote UseItem (dual-hash / posicional) vivia aca y se fue
-- entero: el gancho ya NO dispara ningun remote. Lo activa el propio
-- HookScript del juego via tool:Activate(), asi que no hay nada que resolver
-- -- ver el bloque GRAPPLE mas abajo. Con el se fueron tambien CallClean y
-- CleanFire, que no tenian otro uso, y las ultimas lecturas de la carpeta Net.

local function OnCarpet()
    local Char = LocalPlayer.Character
    if not Char then return false end
    for _, Name in ipairs(CARPET_NAMES) do
        if Char:FindFirstChild(Name) then return true end
    end
    return false
end

-- ============================================================
-- GRAPPLE -- portado del hub de referencia (hub.txt, _G.SXEFireGrapple2 /
-- __SXEGrappleDisparar). Copiado tal cual, con las jarras como objetivo.
-- ------------------------------------------------------------
-- ANTES ESTO NO HACIA NADA. Se disparaba el remote UseItem con un escalar
-- suelto (FireServer(0.33)), creyendo -- por un comentario de sab_com.lua, una
-- version vieja de la referencia -- que esa era la firma. El hub nuevo
-- documenta que no:
--
--   "O hub mandava so o primeiro -- um 0.33 solto, sem posicao e sem peca
--    alvo -- e o servidor nao tinha como saber pra onde puxar. Dai o silencio."
--
-- Mandar los tres argumentos reales (Magnitude/120, Hit.Position, alvo, que es
-- lo que hacen los items hermanos en texto claro) tampoco alcanza: el
-- HookScript de la Grapple esta ofuscado con Luraph y su firma no es la misma.
--
-- Lo que SI funciona es no tocar el remote y hacer que el script del juego arme
-- la llamada solo:
--
--   1. se elige un punto del piso en direccion al objetivo, entre 10 y 50
--      studs (la franja que el item acepta);
--   2. se le escribe Hit/Target al PlayerMouse;
--   3. se gira la camara para que el rayo del cursor apunte a ese punto -- el
--      HookScript arma su rayo con GetMouseLocation() + camara;
--   4. se llama tool:Activate() EN EL MISMO FRAME, sin un solo yield en el
--      medio: el modulo recalcula la mira en cada PreRender y pisaria lo
--      escrito.
--
-- Va todo en una tabla y no como funciones sueltas por el tope de 200 locales
-- del chunk (ver el comentario de `Hop` arriba).
local Grapple = { }

-- La franja que el item exige. Afuera de esto no dispara.
local GRAPPLE_MIN, GRAPPLE_MAX = 10, 50

-- Distancias a las que se busca piso, en direccion al objetivo. Se prueban
-- TODAS y gana la MAS CERCANA que caiga en la franja -- el hub aclara que
-- quedarse con la primera valida barriendo de lejos a cerca terminaba eligiendo
-- casi siempre la mas lejana.
local GRAPPLE_STEPS = { 9, 10, 11, 12, 13, 14, 16, 18, 21, 24, 28, 32, 36, 40, 45 }
-- Sin piso en ningun lado (volando, un pozo): rayo recto en la direccion pedida.
local GRAPPLE_STRAIGHT = { 11, 14, 18, 24, 32, 42, 48 }

-- Entre el hook y el vuelo. NO puede ser cero: Activate() solo ENCOLA el
-- handler (Roblox usa SignalBehavior = Deferred), asi que en el frame del
-- disparo el script del item todavia ni corrio. Y si el vuelo arranca antes,
-- lo primero que hace es equipar la carpet -- que SACA la Grapple Hook de la
-- mano; cuando el handler por fin corre, testea Tool.Name == "Grapple Hook",
-- no la encuentra, y se va sin disparar.
local GRAPPLE_TO_TP = 0.12

-- El gancho tiene cooldown propio del juego: no vuelve a activarse antes de
-- ~3s de la ultima vez. Smart TP usa esto para decidir si puede tirar de el
-- de nuevo o si por ahora solo puede confiar en la carpet.
local GRAPPLE_COOLDOWN = 3
local LastGrappleFire = 0

local function GrappleReady()
    return (os.clock() - LastGrappleFire) >= GRAPPLE_COOLDOWN
end

--- Las tablas con forma de PlayerMouse a las que hay que escribirles la mira.
---
--- Son varias y no una: el hub explica que el require del ejecutor tiene cache
--- propio, asi que devuelve una tabla NUEVA que tambien se conecta al PreRender
--- y tambien tiene valores vivos -- parece la correcta, pero el HookScript lee
--- la OTRA. Ellos lo resuelven barriendo el heap.
---
--- Nosotros pedimos primero la del juego con Env.Require (ver ENV LEAK), que es
--- exactamente la que el HookScript lee -- pero solo si Env.Safe confirmo que
--- hay un require real por detras (getrenv funciono). Sin eso, ese require
--- seria el del ejecutor de siempre, y directamente no se llama: se salta al
--- barrido del heap, que no re-ejecuta nada porque no requiere nada.
--- Se cachea: el barrido no es gratis.
function Grapple.Refs()
    if Grapple.__refs then return Grapple.__refs end

    local Refs, Vistos = { }, { }
    local function Juntar(T)
        if type(T) == "table" and not Vistos[T] then
            Vistos[T] = true
            Refs[#Refs + 1] = T
        end
    end

    if Env.Safe then
        pcall(function()
            local Packages = ReplicatedStorage:FindFirstChild("Packages")
            local Module = Packages and Packages:FindFirstChild("PlayerMouse")
            if not Module then return end
            local OK, Mod = Env.Require(Module)
            if OK then Juntar(Mod) end
        end)
    end

    pcall(function()
        if type(getgc) ~= "function" then return end
        for _, V in ipairs(getgc(true)) do
            if type(V) == "table" and typeof(rawget(V, "Hit")) == "CFrame" then
                local N = 0
                for _ in pairs(V) do N = N + 1 end
                if N <= 3 then Juntar(V) end
            end
        end
    end)

    Grapple.__refs = Refs
    return Refs
end

--- El disparo en si (= __SXEGrappleDisparar). Escribe la mira, gira la camara y
--- activa la tool, todo en el mismo frame. Despues sostiene los valores 4
--- frames -- el modulo los recalcula en cada PreRender -- y restaura.
function Grapple.Shoot(Tool, Pos, Alvo)
    local Refs = Grapple.Refs()

    -- La camara: el HookScript arma el rayo desde GetMouseLocation() + camara,
    -- asi que se la gira de modo que el rayo del cursor -- este donde este --
    -- apunte a nuestro punto.
    local Cam = Workspace.CurrentCamera
    local CamAntes = Cam and Cam.CFrame
    local CamNueva
    if Cam then
        pcall(function()
            local M = UserInputService:GetMouseLocation()
            local Rayo = Cam:ViewportPointToRay(M.X, M.Y)
            local L = Cam.CFrame:VectorToObjectSpace(Rayo.Direction).Unit
            local D = Pos - Cam.CFrame.Position
            if D.Magnitude > 0.01 then
                D = D.Unit
                CamNueva = CFrame.new(Cam.CFrame.Position)
                    * (CFrame.lookAt(Vector3.zero, D) * CFrame.lookAt(Vector3.zero, L):Inverse())
            end
        end)
    end

    local Mira = CFrame.new(Pos)
    local Antes = { }
    for I, T in ipairs(Refs) do
        Antes[I] = { rawget(T, "Hit"), rawget(T, "Target") }
        pcall(function() T.Hit = Mira; T.Target = Alvo end)
    end
    if CamNueva then Cam.CFrame = CamNueva end

    local OK = pcall(function() Tool:Activate() end)
    if not OK and typeof(firesignal) == "function" then
        OK = pcall(function() firesignal(Tool.Activated) end)
    end

    task.spawn(function()
        for _ = 1, 4 do
            if CamNueva and Cam then Cam.CFrame = CamNueva end
            for _, T in ipairs(Refs) do
                pcall(function() T.Hit = Mira; T.Target = Alvo end)
            end
            RunService.Heartbeat:Wait()
        end
        if CamNueva and Cam and CamAntes then Cam.CFrame = CamAntes end
        for I, T in ipairs(Refs) do
            local A = Antes[I]
            pcall(function() T.Hit = A[1]; T.Target = A[2] end)
        end
    end)

    return OK
end

--- Elige el punto y dispara (= SXEFireGrapple2).
---
--- `Value` es a donde queremos ir (la jarra). Con `Exacto`, se usa ese punto
--- tal cual, sin buscar ni achatar -- el hub lo agrego porque el modo de
--- busqueda achata la direccion al plano XZ, y con un objetivo casi debajo de
--- los pies la horizontal da ~cero y termina mirando al frente.
---
--- Sin `Exacto` entra el modo de BUSQUEDA: agarra la direccion horizontal hasta
--- el objetivo y busca piso; o sea, te tira EN DIRECCION a la jarra, rasante.
--- Eso es lo que queremos casi siempre, porque la jarra suele estar mucho mas
--- lejos que los 50 studs que el gancho alcanza.
function Grapple.Fire(Value, Exacto)
    local Char = LocalPlayer.Character
    local HRP = Char and Char:FindFirstChild("HumanoidRootPart")
    if not HRP then return false end

    -- Mismo guardia que el hub: durante un robo no se dispara.
    if LocalPlayer:GetAttribute("Stealing") then return false end

    -- El equip va ACA, antes de todo: mas adelante, entre escribir la mira y
    -- llamar a Activate(), no puede haber un solo yield.
    local Tool = Char:FindFirstChild("Grapple Hook")
    if not Tool then
        local Backpack = FindTool("Grapple Hook")
        local Humanoid = Char:FindFirstChildOfClass("Humanoid")
        if not Backpack or not Humanoid then
            if not Grapple.__warned then
                Grapple.__warned = true
                warn("[HONEY TP] Grapple: no 'Grapple Hook' in character or backpack")
            end
            return false
        end
        pcall(function() Humanoid:EquipTool(Backpack) end)
        local T0 = os.clock()
        repeat
            RunService.Heartbeat:Wait()
            Char = LocalPlayer.Character
            Tool = Char and Char:FindFirstChild("Grapple Hook")
        until Tool or os.clock() - T0 > 0.5
        if not Tool then return false end
        HRP = Char:FindFirstChild("HumanoidRootPart")
        if not HRP then return false end
    end

    local Par = RaycastParams.new()
    Par.FilterType = Enum.RaycastFilterType.Exclude
    Par.FilterDescendantsInstances = { Char }

    -- ── mira exacta ──────────────────────────────────────────────────────
    if Exacto and typeof(Value) == "Vector3" then
        local M = (Value - HRP.Position).Magnitude
        if M < GRAPPLE_MIN or M > GRAPPLE_MAX then return false end

        local Alvo
        local Hit = Workspace:Raycast(HRP.Position, Value - HRP.Position, Par)
        if Hit then Alvo = Hit.Instance end
        if not Alvo then
            for _, P in ipairs(Workspace:GetPartBoundsInRadius(Value, 6)) do
                if P:IsA("BasePart") and not P:IsDescendantOf(Char) then Alvo = P; break end
            end
        end
        if not Alvo then return false end
        return Grapple.Shoot(Tool, Value, Alvo)
    end

    -- ── modo busqueda: piso en direccion al objetivo ─────────────────────
    local Destino
    if typeof(Value) == "Vector3" then Destino = Value
    elseif typeof(Value) == "Instance" and Value:IsA("BasePart") then Destino = Value.Position end

    local Dir
    if Destino then
        Dir = Destino - HRP.Position
        Dir = Vector3.new(Dir.X, 0, Dir.Z)
    end
    if not Dir or Dir.Magnitude < 1 then
        local LV = HRP.CFrame.LookVector
        Dir = Vector3.new(LV.X, 0, LV.Z)
    end
    if Dir.Magnitude < 0.01 then return false end
    Dir = Dir.Unit

    -- El rayo arranca 3 studs sobre la cabeza y baja 60, no 30 studs POR
    -- ENCIMA: adentro de una base eso ponia el origen arriba del techo y el
    -- rayo pegaba en el tejado -- era el "gancho al techo de mi base".
    local Pos, Alvo, MejorM
    for _, D in ipairs(GRAPPLE_STEPS) do
        local Origen = HRP.Position + Dir * D + Vector3.new(0, 3, 0)
        local Hit = Workspace:Raycast(Origen, Vector3.new(0, -60, 0), Par)
        if Hit then
            local M = (Hit.Position - HRP.Position).Magnitude
            if M >= GRAPPLE_MIN and M <= GRAPPLE_MAX and (not MejorM or M < MejorM) then
                Pos, Alvo, MejorM = Hit.Position, Hit.Instance, M
            end
        end
    end

    if not Pos then
        for _, D in ipairs(GRAPPLE_STRAIGHT) do
            local Hit = Workspace:Raycast(HRP.Position, Dir * D, Par)
            if Hit then
                local M = (Hit.Position - HRP.Position).Magnitude
                if M >= GRAPPLE_MIN and M <= GRAPPLE_MAX and (not MejorM or M < MejorM) then
                    Pos, Alvo, MejorM = Hit.Position, Hit.Instance, M
                end
            end
        end
    end
    if not Pos or not Alvo then return false end

    return Grapple.Shoot(Tool, Pos, Alvo)
end

--- Lo que llama el resto del collector. `Target` es la jarra a la que vamos:
--- si ya esta dentro del alcance del gancho se apunta exacto, y si no, se tira
--- en su direccion.
local function FireGrapple(Target)
    local HRP = GetRoot()
    if not HRP then return false end

    local Exacto = false
    if typeof(Target) == "Vector3" then
        local M = (Target - HRP.Position).Magnitude
        Exacto = M >= GRAPPLE_MIN and M <= GRAPPLE_MAX
    end

    local OK = Grapple.Fire(Target, Exacto)
    if OK then LastGrappleFire = os.clock() end
    return OK
end

-- Equipar la carpet tras el tiron. El gancho ya se disparo antes en
-- MoveToPosition (via task.spawn), asi que aca solo se espera a que el tiron
-- registre (0.22s), se sueltan herramientas y se monta la carpet.
local function CarpetEngage()
    local Char = LocalPlayer.Character
    local Humanoid = Char and Char:FindFirstChildOfClass("Humanoid")
    if not Char or not Humanoid then return nil end

    -- MoveToPosition ya disparo el gancho y ya espero GRAPPLE_TO_TP, que es lo
    -- que el handler diferido del item necesita para arrancar. Lo de aca es el
    -- resto del tiempo de vuelo del proyectil antes de soltar herramientas.
    task.wait(0.10)

    local Hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if Hum then pcall(function() Hum:UnequipTools() end) end

    task.wait(0.10)
    local ChosenName
    local RetryStart = os.clock()
    repeat
        ChosenName = EquipCarpet()
        local C = LocalPlayer.Character
        if ChosenName and C and C:FindFirstChild(ChosenName) then break end
        RunService.Heartbeat:Wait()
    until os.clock() - RetryStart > 1

    return ChosenName
end

local ARRIVE = 3

-- ============================================================
-- VELOCITY ZERO / PATH VIZ
-- ============================================================
local function VZero(HRP)
    if not HRP or not HRP.Parent then return end
    HRP.AssemblyLinearVelocity = Vector3.zero
    HRP.AssemblyAngularVelocity = Vector3.zero
end

-- Viz: cyan neon lines + yellow dots drawn along the route while the TP runs.
-- Mirrors sab_com.lua lines 5689-5730. Toggle with _G.honeyTPShowPath.
local _vizParts = {}

local function clearViz()
    for _, P in ipairs(_vizParts) do if P and P.Parent then P:Destroy() end end
    table.clear(_vizParts)
end

local function vizLine(A, B, Color3Val)
    local D = B - A
    if D.Magnitude < 0.05 then return end
    local P = Instance.new("Part")
    P.Anchored = true; P.CanCollide = false; P.CanQuery = false; P.CastShadow = false
    P.Material = Enum.Material.Neon; P.Color = Color3Val
    P.Size = Vector3.new(0.4, 0.4, D.Magnitude)
    P.CFrame = CFrame.new((A + B) / 2, B)
    P.Parent = Workspace
    _vizParts[#_vizParts + 1] = P
end

local function vizDot(Pos, Color3Val, Sz)
    local P = Instance.new("Part")
    P.Anchored = true; P.CanCollide = false; P.CanQuery = false; P.CastShadow = false
    P.Shape = Enum.PartType.Ball; P.Material = Enum.Material.Neon; P.Color = Color3Val
    P.Size = Vector3.new(Sz, Sz, Sz)
    P.Position = Pos
    P.Parent = Workspace
    _vizParts[#_vizParts + 1] = P
end

local function vizPath(FromPos, Waypoints)
    if G.honeyTPShowPath == false then return end
    if not FromPos or not Waypoints or #Waypoints == 0 then return end
    clearViz()
    local LINE = Color3.fromRGB(0, 200, 255)
    local DOT  = Color3.fromRGB(255, 255, 0)
    vizDot(FromPos, DOT, 1.5)
    local Prev = FromPos
    for _, WP in ipairs(Waypoints) do
        vizLine(Prev, WP, LINE)
        vizDot(WP, DOT, 1.5)
        Prev = WP
    end
end

local function LvStop(HRP)
    if HRP and HRP.Parent then
        HRP.AssemblyLinearVelocity = Vector3.zero
        HRP.AssemblyAngularVelocity = Vector3.zero
    end
end

-- Tope de componente vertical de la velocidad. El hub de referencia usa 60: mas
-- alto que eso el drive sube demasiado rapido y sobrepasa el objetivo en Y antes
-- de haber avanzado en horizontal.
local MAX_CLIMB = 60

local function ClimbCap()
    return tonumber(Config.Climb) or MAX_CLIMB
end

-- ============================================================
-- OBSTACLE AVOIDANCE (ported from sab_com.lua _block/_clear/computeRoute)
-- ------------------------------------------------------------
-- BuildRoute antes iba siempre en linea recta interpolando altura -- nunca
-- chequeaba si habia una pared en el medio, por eso el TP la cruzaba entera.
-- Esta capa raycastea el tramo: si esta despejado usa la linea recta de
-- siempre; si algo bloquea (pared, base, piso), pathfinea alrededor con
-- PathfindingService y comprime el resultado con string-pulling.
-- ============================================================
local PathfindingService = game:GetService("PathfindingService")

local ROUTE_STRUCT = { ["structure base home"] = true, ["Wall"] = true, ["Floor"] = true, ["Roof"] = true }
local ROUTE_SKIP_NAME = { ["DeliveryHitbox"]=true, ["StealHitbox"]=true, ["LaserHitbox"]=true,
    ["AnimalTarget"]=true, ["Multiplier"]=true, ["Laser"]=true, ["Hitbox"]=true,
    ["Spawn"]=true, ["MainRoot"]=true, ["SecondFloor"]=true, ["ThirdFloor"]=true, ["Slope"]=true }

-- Distingue "pared real" de props/hitboxes chicas que no deberian frenar la
-- ruta: cualquier cosa con CanCollide, las estructuras nombradas de base, o
-- cualquier parte grande (> 150 en su cara mas ancha).
local function RouteBlocks(Inst)
    if not Inst then return false end
    if ROUTE_SKIP_NAME[Inst.Name] then return false end
    if Inst.CanCollide then return true end
    if ROUTE_STRUCT[Inst.Name] then return true end
    local S = Inst.Size
    if S and math.max(S.X * S.Y, S.X * S.Z, S.Y * S.Z) > 150 then return true end
    return false
end

-- Raycast en cadena: salta lo que no bloquea (props, hitboxes) y sigue
-- avanzando desde ahi, hasta pegar en algo real o llegar al destino limpio.
local function RouteBlock(Origin, Target)
    local Rp = RaycastParams.new()
    Rp.FilterType = Enum.RaycastFilterType.Exclude
    Rp.IgnoreWater = true
    local Skip = { }
    for _, Plr in ipairs(Players:GetPlayers()) do
        if Plr.Character then table.insert(Skip, Plr.Character) end
    end
    local O = Origin
    for _ = 1, 16 do
        Rp.FilterDescendantsInstances = Skip
        local D = Target - O
        if D.Magnitude < 0.05 then return nil end
        local Res = Workspace:Raycast(O, D, Rp)
        if not Res then return nil end
        if RouteBlocks(Res.Instance) then return Res end
        table.insert(Skip, Res.Instance)
        O = Res.Position + D.Unit * 0.3
    end
    return nil
end

local function RouteClear(A, B) return RouteBlock(A, B) == nil end

local ROUTE_CLEARANCE = 6
-- Linea de vision "ancha": ademas del centro, chequea dos rayos paralelos
-- desplazados a los costados, para no colar la ruta pegada a una esquina.
local function RouteClearWide(A, B)
    if not RouteClear(A, B) then return false end
    local D = Vector3.new(B.X - A.X, 0, B.Z - A.Z)
    if D.Magnitude < 0.1 then return true end
    local P = Vector3.new(-D.Z, 0, D.X).Unit * ROUTE_CLEARANCE
    return RouteClear(A + P, B + P) and RouteClear(A - P, B - P)
end

-- String-pulling: de cada punto salta al mas lejano que siga en linea de
-- vision, asi el pathfinder no deja un waypoint cada 4 studs.
local function RoutePullWide(Pts)
    if #Pts <= 2 then return Pts end
    local Out = { Pts[1] }
    local I = 1
    while I < #Pts do
        local J = #Pts
        while J > I + 1 and not RouteClearWide(Out[#Out], Pts[J]) do J = J - 1 end
        table.insert(Out, Pts[J])
        I = J
    end
    return Out
end

-- Si hay linea de vision directa no hace falta nada mas: un solo punto. Si
-- algo bloquea, PathfindingService calcula el rodeo por el piso y despues se
-- comprime con RoutePullWide para que BuildRoute no tenga que interpolar
-- decenas de waypoints redundantes.
local function PathfindRoute(FromPos, ToPos)
    if RouteClear(FromPos, ToPos) then return { ToPos } end

    local GroundTo = Vector3.new(ToPos.X, FromPos.Y, ToPos.Z)
    local Path = PathfindingService:CreatePath({
        AgentRadius = 8, AgentHeight = 5, AgentCanJump = true, AgentJumpHeight = 10, AgentMaxSlope = 89,
    })
    local FLOAT = 3
    local Nav = { FromPos }
    local OK = pcall(function()
        Path:ComputeAsync(Vector3.new(FromPos.X, FromPos.Y, FromPos.Z), GroundTo)
    end)
    if OK and Path.Status == Enum.PathStatus.Success then
        local Last = FromPos
        for _, Wp in ipairs(Path:GetWaypoints()) do
            if (Wp.Position - Last).Magnitude >= 8 then
                table.insert(Nav, Wp.Position + Vector3.new(0, FLOAT, 0))
                Last = Wp.Position
            end
        end
    end
    table.insert(Nav, ToPos + Vector3.new(0, FLOAT, 0))
    local Route = RoutePullWide(Nav)
    table.insert(Route, ToPos)
    return Route
end

-- Trazado del hub de referencia. La clave: la altura se interpola contra el
-- avance HORIZONTAL acumulado, no contra el indice del waypoint. Eso produce un
-- planeo diagonal parejo en vez de "subir en vertical y despues cruzar". Cada
-- tramo se parte en segmentos planos de 30 studs para que la rampa quede fina.
--
-- Los waypoints crudos ya no son siempre "ir directo": si RouteClear detecta
-- pared en el medio, PathfindRoute mete un rodeo antes de que esto interpole.
local ROUTE_SEG = 30

local function BuildRoute(FromPos, ToPos)
    local Raw = PathfindRoute(FromPos, ToPos)

    local StartY, DestY = FromPos.Y, ToPos.Y
    local Prev = FromPos
    local TotalFlat = 0
    for _, WP in ipairs(Raw) do
        TotalFlat = TotalFlat
            + (Vector3.new(WP.X, 0, WP.Z) - Vector3.new(Prev.X, 0, Prev.Z)).Magnitude
        Prev = WP
    end
    if TotalFlat < 0.01 then TotalFlat = 0.01 end

    local Route = { }
    Prev = FromPos
    local Travelled = 0
    for _, WP in ipairs(Raw) do
        local FlatVec = Vector3.new(WP.X, 0, WP.Z) - Vector3.new(Prev.X, 0, Prev.Z)
        local LegFlat = FlatVec.Magnitude
        if LegFlat >= 0.01 then
            local Subs = math.max(1, math.ceil(LegFlat / ROUTE_SEG))
            for S = 1, Subs do
                local F = S / Subs
                local Along = Travelled + LegFlat * F
                table.insert(Route, Vector3.new(
                    Prev.X + (WP.X - Prev.X) * F,
                    StartY + (DestY - StartY) * (Along / TotalFlat),
                    Prev.Z + (WP.Z - Prev.Z) * F
                ))
            end
        else
            table.insert(Route, WP)
        end
        Travelled = Travelled + LegFlat
        Prev = WP
    end

    if #Route > 0 then Route[#Route] = ToPos end
    return Route
end

-- Micro-pasos crudos por CFrame antes de que arranque el drive de velocidad:
-- el LinearVelocity tarda un par de frames en acelerar a full, y en tramos
-- cortos eso se siente como que el personaje no arranco. Cada paso se valida
-- con un raycast excluyendo a los jugadores, asi que nunca cruza algo solido.
local QUICKSTART_STEPS = 3
local QUICKSTART_STEP_DIST = 20

local function QuickStart(HRP, Waypoints, WpIdx)
    local Params = RaycastParams.new()
    Params.FilterType = Enum.RaycastFilterType.Exclude
    Params.IgnoreWater = true
    local Skip = { }
    for _, Plr in ipairs(Players:GetPlayers()) do
        if Plr.Character then table.insert(Skip, Plr.Character) end
    end
    Params.FilterDescendantsInstances = Skip

    for _ = 1, QUICKSTART_STEPS do
        local Target = Waypoints[WpIdx]
        if not Target or Cancel then break end

        local Flat = Vector3.new(Target.X - HRP.Position.X, 0, Target.Z - HRP.Position.Z)
        local Mag = Flat.Magnitude
        if Mag < 1 then break end

        local NextPos = HRP.Position + Flat.Unit * math.min(QUICKSTART_STEP_DIST, Mag)
        local OK, Hit = pcall(workspace.Raycast, workspace, HRP.Position, NextPos - HRP.Position, Params)
        if OK and Hit and Hit.Instance and Hit.Instance.CanCollide then break end

        HRP.CFrame = (HRP.CFrame - HRP.CFrame.Position) + NextPos
        HRP.AssemblyLinearVelocity = Vector3.zero
        HRP.AssemblyAngularVelocity = Vector3.zero
        RunService.Heartbeat:Wait()
        if not HRP or not HRP.Parent then return end
    end
end

local function VelMoveThrough(HRP, Waypoints, SpeedOverride, AllowJump)
    if not HRP or not HRP.Parent or #Waypoints == 0 then return end
    local RunSpeed = SpeedOverride or Config.Speed or 280
    local WpIdx = 1
    local Done = false
    local Conn

    local function Finish()
        if Done then return end
        Done = true
        clearViz()
        if HRP and HRP.Parent then
            LvStop(HRP)
            local _, Y = HRP.CFrame:ToEulerAnglesYXZ()
            HRP.CFrame = CFrame.new(Waypoints[#Waypoints]) * CFrame.Angles(0, Y, 0)
        end
        if Conn then Conn:Disconnect() end
    end
    local function CancelStop()
        if Done then return end
        Done = true
        clearViz()
        if HRP and HRP.Parent then LvStop(HRP) end
        if Conn then Conn:Disconnect() end
    end

    local LastDist, Stall = math.huge, 0

    vizPath(HRP.Position, Waypoints)

    QuickStart(HRP, Waypoints, WpIdx)
    if Cancel or not HRP or not HRP.Parent then clearViz(); return end

    do
        local Peak = HRP.Position.Y
        for _, WP in ipairs(Waypoints) do if WP.Y > Peak then Peak = WP.Y end end
        if Peak > HRP.Position.Y + 3 then
            local Hum = HRP.Parent and HRP.Parent:FindFirstChildOfClass("Humanoid")
            if Hum then
                pcall(function() Hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
                pcall(function() Hum.Jump = true end)
            end
        end
    end

    Conn = RunService.Heartbeat:Connect(function()
        if not HRP or not HRP.Parent or Done then
            if Conn then Conn:Disconnect() end
            return
        end
        if Cancel then CancelStop(); return end
        EquipCarpet()

        local Target = Waypoints[WpIdx]
        local Diff = Target - HRP.Position
        local Mag = Diff.Magnitude
        local Spd = RunSpeed

        local Arr = math.max(ARRIVE, Spd / 60 * 1.25)
        if Mag < Arr then
            WpIdx = WpIdx + 1
            if WpIdx > #Waypoints then Finish(); return end
            LastDist, Stall = math.huge, 0
            Target = Waypoints[WpIdx]
            Diff = Target - HRP.Position
            Mag = Diff.Magnitude
        end

        if Mag > LastDist - 0.05 then Stall = Stall + 1 else Stall = 0 end
        LastDist = Mag
        if Stall >= 18 then Finish(); return end

        if Mag >= 0.1 then
            local Dir = Diff.Unit
            if (AllowJump or Diff.Y > 10) and Diff.Y > 5 and WpIdx < #Waypoints then
                local Hum = HRP.Parent and HRP.Parent:FindFirstChildOfClass("Humanoid")
                if Hum then
                    local St = Hum:GetState()
                    if St ~= Enum.HumanoidStateType.Jumping and St ~= Enum.HumanoidStateType.Freefall then
                        pcall(function() Hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
                        pcall(function() Hum.Jump = true end)
                    end
                end
            end
            local _sp = Spd
            local _vy = Dir.Y * _sp
            local Mc = ClimbCap()
            if _vy > Mc then _vy = Mc end
            HRP.Velocity = Vector3.new(Dir.X * _sp, _vy, Dir.Z * _sp)
        end
    end)

    local TotalDist = 0
    local Prev = HRP.Position
    for _, WP in ipairs(Waypoints) do
        TotalDist = TotalDist + (Prev - WP).Magnitude
        Prev = WP
    end
    local Timeout = TotalDist / math.max(1, math.min(200, RunSpeed)) + 2
    local Elapsed = 0
    while not Done and Elapsed < Timeout do
        task.wait(0.05)
        Elapsed = Elapsed + 0.05
        if Cancel then break end
    end
    if Cancel then CancelStop() else Finish() end
    LvStop(HRP)
end

-- El drive de velocidad no sube bien un tramo vertical largo de una sola vez:
-- se queda raspando y el detector de stall lo corta. El hub parte cualquier
-- ascenso en escalones de 10 studs.
local ASCEND_STEP = 10

local function StepRoute(FromPos, Route)
    local Stepped = { }
    local Prev = FromPos
    for _, WP in ipairs(Route) do
        local Dy = WP.Y - Prev.Y
        if Dy > ASCEND_STEP * 1.5 then
            local N = math.ceil(Dy / ASCEND_STEP)
            for S = 1, N - 1 do
                local T = S / N
                table.insert(Stepped, Vector3.new(
                    Prev.X + (WP.X - Prev.X) * T,
                    Prev.Y + Dy * T,
                    Prev.Z + (WP.Z - Prev.Z) * T
                ))
            end
        end
        table.insert(Stepped, WP)
        Prev = WP
    end
    return Stepped
end

local function RouteLength(FromPos, Route)
    local Total = 0
    local Prev = FromPos
    for _, WP in ipairs(Route) do
        Total = Total + (WP - Prev).Magnitude
        Prev = WP
    end
    return Total
end

-- Smart TP: el modo Grapple fijo dispara el gancho en CADA intento sin mirar
-- la distancia -- si el timing no da (todavia en cooldown real del juego),
-- simplemente lo vuelve a intentar en el proximo TP. Smart imita exactamente
-- eso: usa Grapple siempre que nuestro tracker de cooldown lo de listo, sin
-- techo de distancia (antes Config.SmartGrappleRange cortaba a Carpet en
-- tramos largos aunque el gancho estuviera disponible, que es lo que hacia
-- que "no lo usara"). Solo cae a Carpet cuando el gancho esta en cooldown, y
-- ahi a Config.SmartFallbackSpeed porque la carpet sola no es confiable a
-- full velocidad en tramos largos.
local function SmartPickMethod()
    if GrappleReady() then
        return "Grapple", nil
    end
    return "Carpet", Config.SmartFallbackSpeed
end

-- Mismo orden que DoVelocityTP del hub: fijar la vida, enganchar, frenar en
-- seco, trazar, escalonar y recien ahi volar.
local function MoveToPosition(Target)
    local HRP = GetRoot()
    local Humanoid = GetHumanoid()
    if not HRP then return end

    local Method = Config.Method
    local SmartSpeedOverride = nil
    if Config.SmartTP then
        Method, SmartSpeedOverride = SmartPickMethod()
    end

    -- El tiron del gancho y el vuelo rapido pueden matarte a mitad de camino, y
    -- el hub clava la vida para evitarlo. Pero alla es un disparo puntual por
    -- viaje; aca el loop lo repetiria sin parar, y escribir Health desde el
    -- cliente en cada frame es de lo mas facil de detectar que hay. Queda
    -- opcional y apagado.
    local HealConn
    if Config.HealthLock and Humanoid then
        local MaxHP = Humanoid.MaxHealth
        Humanoid.Health = MaxHP
        HealConn = RunService.Heartbeat:Connect(function()
            if Humanoid and Humanoid.Parent then Humanoid.Health = MaxHP end
        end)
    end

    if Method == "Grapple" then
        -- SECUENCIAL, no en paralelo -- es el orden del hub (SXECicloTP) y es
        -- obligatorio. Antes esto era un task.spawn y el engage corria al mismo
        -- tiempo: a los 0.22s hacia UnequipTools(), que le sacaba la Grapple
        -- Hook de la mano ANTES de que el handler diferido del item llegara a
        -- correr. El item testea Tool.Name == "Grapple Hook", no la encontraba,
        -- y se iba sin disparar.
        pcall(FireGrapple, Target)
        task.wait(GRAPPLE_TO_TP)
        -- El engage solo hace falta una vez por vuelo: si ya venis en la carpet,
        -- repetirlo te tira al piso entre jar y jar.
        if not OnCarpet() then CarpetEngage() end
        LvStop(HRP)
    else
        EquipCarpet()
        LvStop(HRP)
    end

    local Route = BuildRoute(HRP.Position, Target)
    local Stepped = StepRoute(HRP.Position, Route)
    -- En tramos cortos la velocidad alta se pasa de largo y rebota.
    local Len = RouteLength(HRP.Position, Route)
    local MainSpeed = (Len < 100) and math.min(200, Config.Speed) or Config.Speed
    if SmartSpeedOverride then MainSpeed = math.min(MainSpeed, SmartSpeedOverride) end
    VelMoveThrough(HRP, Stepped, MainSpeed, true)

    if HRP and HRP.Parent then
        HRP.AssemblyLinearVelocity = Vector3.zero
        HRP.AssemblyAngularVelocity = Vector3.zero
    end
    if HealConn then HealConn:Disconnect() end
end

-- ============================================================
-- HONEY
-- ============================================================
local Collected = 0

local function IsHoney(Obj)
    local Name = tostring(Obj.Name or ""):lower()
    return Name == "honey" or Name:find("honey jar", 1, true) ~= nil or Name:find("honeyjar", 1, true) ~= nil
end

-- El script original miraba solo los hijos directos de Workspace con nombre
-- exacto "Honey". Si en el server los jars cuelgan de un contenedor, no
-- encontraba ninguno y el collector se quedaba mirando la pared. Aca se indexa
-- el Workspace entero una vez y despues se mantiene vivo con los eventos, que
-- sale mas barato que rebarrer cada decima de segundo.
local Tracked = { }

-- El evento clona cada abeja como "Event Bee - <trait>" y la cuelga derecho de
-- Workspace (createBeeModel en el modulo Bee del juego). Verlas es prueba de
-- que el evento corre, y a diferencia de las jarras siguen ahi aunque ya se
-- haya juntado todo -- por eso vale la pena indexarlas. Se aprovecha la misma
-- conexion que ya recorre el Workspace en vez de abrir otra.
local function TrackCandidate(Obj)
    if Tracked[Obj] then return end
    if Obj:IsA("Model") and Obj.Name:sub(1, 11) == "Event Bee -" then
        Bee.Models[Obj] = true
        return
    end
    if not (Obj:IsA("Model") or Obj:IsA("BasePart")) then return end
    if not IsHoney(Obj) then return end
    -- Un jar que es Model tiene sus partes adentro; quedarse con el padre evita
    -- meter cada pieza como si fuera un jar aparte.
    if Obj:IsA("BasePart") and Obj.Parent and Obj.Parent:IsA("Model") and IsHoney(Obj.Parent) then
        return
    end
    Tracked[Obj] = true
end

for _, Obj in ipairs(Workspace:GetDescendants()) do TrackCandidate(Obj) end

Workspace.DescendantAdded:Connect(TrackCandidate)
Workspace.DescendantRemoving:Connect(function(Obj)
    Tracked[Obj] = nil
    Bee.Models[Obj] = nil
end)

local function ScanHoney()
    local Out = { }
    for Obj in pairs(Tracked) do
        if Obj.Parent then
            table.insert(Out, Obj)
        else
            Tracked[Obj] = nil
        end
    end
    return Out
end

-- ============================================================
-- EVENT TRACKER -- esta corriendo el evento Bee?
-- ------------------------------------------------------------
-- Dos capas: la fuente autoritativa del juego, y las huellas que el evento
-- deja en el mapa por si aquella no se puede leer.
--
-- LA AUTORITATIVA. ReplicatedStorage.Controllers.EventController mantiene
-- ActiveEvents replicado y expone :IsActive("Bee"). Se llega a el con
-- Env.Require, NUNCA con un require crudo (ver el bloque ENV LEAK arriba):
-- crudo, el require del ejecutor no pega en la cache real y re-ejecuta el
-- modulo, que levanta Synchronizer + ReplicatorClient y termina siendo un
-- SEGUNDO cliente de replicacion hablandole al server -- eso es lo que
-- kickeaba. Por Env se usa el require del juego, con identidad 2 y sin
-- frames nuestros en la pila: devuelve la MISMA tabla que ya tiene el
-- cliente, sin ejecutar nada de nuevo. Es la via que honeymerchant.lua usa
-- en produccion sin problemas.
--
-- LAS PASIVAS. Puro FindFirstChild y lectura de propiedades ya replicadas:
-- no pueden kickear porque el server no se entera. Cubren el caso de que el
-- ejecutor no traiga getrenv/getsenv/setthreadidentity y Env quede en nada.
-- Del modulo Bee del juego (EventController.Events.Bee), OnStart/OnStop hacen:
--
--   · La colmena. OnStart pone workspace.Beehive.Active.ActiveNeon.Transparency
--     en 0; OnStop y OnLoad la ponen en 1. Es un booleano de verdad: sirve
--     tanto para decir que si como para decir que no.
--   · Las abejas. createBeeModel clona cada una como "Event Bee - <trait>"
--     derecho en Workspace, y clearVisuals las destruye al cortar. Es la mejor
--     senal positiva: siguen ahi aunque ya se hayan juntado todas las jarras.
--   · Los VFX de la colmena. OnStart hace VFX.enable(Beehive.BeeHiveSpawnVFX)
--     y OnStop lo apaga. Solo se usa para confirmar el SI, porque no esta dicho
--     que enable/disable sea siempre .Enabled de un ParticleEmitter.
--   · Jarras en el mapa. Solo existen con el evento corriendo, asi que ver una
--     es prueba de que esta activo -- pero NO verlas no prueba nada (pueden
--     estar todas juntadas), por eso solo confirma el si.
--
-- Sin ninguna senal se asume apagado: es el lado seguro. Peor que esperar de
-- mas es hopear en vacio, que es justo lo que esto viene a evitar.
Bee.EVENT_NAME = "Bee"

-- El modulo, resuelto una sola vez. false = ya se intento (o ni se intento
-- porque Env no esta protegido) y no se pudo, para no reintentar el cruce en
-- cada refresh.
function Bee.Controller()
    if Bee.__ctrl ~= nil then return Bee.__ctrl or nil end

    -- Sin Env.Safe, RealRequire seria el require del ejecutor -- el que
    -- re-ejecuta el modulo y kickea. Ni se intenta: se cae derecho a las
    -- senales pasivas, que es el mismo resultado que "no se pudo leer" mas
    -- abajo pero sin arriesgar nada.
    if not Env.Safe then
        Bee.__ctrl = false
        if not Bee.__warnedUnsafe then
            Bee.__warnedUnsafe = true
            warn("[HONEY TP] event: este ejecutor no da getrenv -- EventController queda sin tocar, solo senales del mapa")
        end
        return nil
    end

    local Folder = ReplicatedStorage:FindFirstChild("Controllers")
    local Module = Folder and Folder:FindFirstChild("EventController")
    if not Module then return nil end   -- todavia no llego: se reintenta luego

    local OK, Mod = Env.Require(Module)
    Bee.__ctrl = (OK and type(Mod) == "table" and Mod) or false
    if Bee.__ctrl == false then
        warn("[HONEY TP] event: no se pudo leer EventController, se usan las senales del mapa")
    end
    return Bee.__ctrl or nil
end

-- Cada fuente devuelve true, false o nil (= no se cuanto).
function Bee.FromController()
    local Ctrl = Bee.Controller()
    if not Ctrl or type(Ctrl.IsActive) ~= "function" then return nil end
    -- La llamada tambien va por Env: :IsActive baja a GetActiveEvents, que lee
    -- la tabla del Synchronizer del juego. Son lecturas, pero corren adentro
    -- del juego y no cuesta nada que lo hagan con la identidad correcta.
    local OK, Active = Env.Call(Ctrl.IsActive, Ctrl, Bee.EVENT_NAME)
    if OK and type(Active) == "boolean" then return Active end
    return nil
end

function Bee.FromHive()
    local Hive = Workspace:FindFirstChild("Beehive")
    local Active = Hive and Hive:FindFirstChild("Active")
    local Neon = Active and Active:FindFirstChild("ActiveNeon")
    if Neon and Neon:IsA("BasePart") then return Neon.Transparency < 0.5 end
    return nil
end

-- Positiva y nada mas: no ver abejas puede ser streaming, no que el evento se
-- corto. El indice lo mantiene TrackCandidate, asi que esto no barre nada.
function Bee.FromBees()
    for Obj in pairs(Bee.Models) do
        if Obj.Parent then return true end
        Bee.Models[Obj] = nil
    end
    return nil
end

-- Tambien positiva. Con el Optimizer prendido no se consulta: el que apago
-- esos emisores fuimos nosotros, no el fin del evento (por eso ademas Boost
-- deja la colmena afuera del barrido).
function Bee.FromHiveVfx()
    if Config.Optimizer then return nil end
    local Hive = Workspace:FindFirstChild("Beehive")
    local Vfx = Hive and Hive:FindFirstChild("BeeHiveSpawnVFX")
    if not Vfx then return nil end
    for _, Obj in ipairs(Vfx:GetDescendants()) do
        if Obj:IsA("ParticleEmitter") and Obj.Enabled then return true end
    end
    return nil
end

function Bee.Refresh()
    -- Primero la del juego; si no se pudo leer, la colmena.
    local Active, Source = Bee.FromController(), "EventController"
    if Active == nil then Active, Source = Bee.FromHive(), "colmena" end

    -- Cualquier prueba positiva gana sobre un "apagado" o un "no se": si hay
    -- abejas o jarras dando vueltas, el evento corre y hay que juntar.
    if Active ~= true then
        if Bee.FromBees() then
            Active, Source = true, "abejas en el mapa"
        elseif #ScanHoney() > 0 then
            Active, Source = true, "jarras en el mapa"
        elseif Bee.FromHiveVfx() then
            Active, Source = true, "VFX de la colmena"
        end
    end

    if Active == nil then Active, Source = false, "sin senal" end
    Bee.Active, Bee.Source, Bee.CheckedAt = Active, Source, os.clock()
    return Active
end

-- Lo que mira el collector antes de moverse: con WaitEvent apagado nunca frena.
function Bee.ShouldHold()
    return Config.WaitEvent and not Bee.Active
end

local function HoneyPosition(Honey)
    local OK, Pos = pcall(function() return Honey:GetPivot().Position end)
    if OK then return Pos end
    if Honey:IsA("BasePart") then return Honey.Position end
    return nil
end

-- La jarra NO se agarra tocandola. El evento la construye con CanTouch=false en
-- todas sus partes, asi que firetouchinterest no puede hacer nada -- por eso el
-- script original no recolectaba. Quien la reclama es el propio cliente del
-- juego: cuando el ProximityPrompt de la jarra se muestra (estas dentro de
-- MaxActivationDistance, 12 studs, sin requerir linea de vision) su loop dispara
-- EventService/Bee/ClaimHoney con el id. Alcanza con llegar y quedarse ahi.
local function HoneyPrompt(Honey)
    local Part = (Honey:IsA("BasePart") and Honey)
        or Honey.PrimaryPart
        or Honey:FindFirstChildWhichIsA("BasePart", true)
    if not Part then return nil end
    return Part:FindFirstChildWhichIsA("ProximityPrompt", true)
end

local function PromptRange(Honey)
    local Prompt = HoneyPrompt(Honey)
    if Prompt then
        -- Un margen por debajo del limite real, que la jarra flota y oscila.
        return math.max(4, Prompt.MaxActivationDistance - 3)
    end
    return 9
end

local CLAIM_TIMEOUT = 8

local SetStatus

local function CollectHoney(Honey)
    if not Honey or not Honey.Parent then return end

    local Pos = HoneyPosition(Honey)
    if not Pos then return end

    MoveToPosition(Pos)

    -- La jarra cae primero y su prompt no se habilita hasta terminar de caer;
    -- despues queda flotando y oscilando. Hay que esperarla ahi en vez de salir
    -- corriendo al siguiente, y reacomodarse si se corrio de rango.
    local Range = PromptRange(Honey)
    local Deadline = os.clock() + CLAIM_TIMEOUT
    while Honey.Parent and os.clock() < Deadline do
        if not Config.Enabled or Cancel then break end

        local Root = GetRoot()
        if not Root then break end

        local Live = HoneyPosition(Honey)
        if Live and (Root.Position - Live).Magnitude > Range then
            MoveToPosition(Live)
        end

        task.wait(0.1)
    end

    if not Honey.Parent then
        Collected = Collected + 1
    end
end

-- ============================================================
-- AUTO HOP (una vez agotado el server, salta a uno con poca gente)
-- ------------------------------------------------------------
-- Pagina el listado publico de servers en vez de pedir la primera pagina y
-- quedarse con el primero que tenga lugar: asi encuentra uno realmente vacio
-- (idealmente con 1 jugador -- nosotros mismos al entrar) en vez de saltar a
-- cualquier server con hueco.
-- ============================================================
local HOP_MAX_PLAYERS = 2
-- Tope de paginas (100 servers c/u) para no quedarse pagineando para siempre
-- en un juego con muchos servers activos ni comerse un rate-limit de Roblox.
local HOP_MAX_PAGES = 8

-- El listado pide el PLACE id, el mismo que despues se le pasa a
-- TeleportToPlaceInstance. Hubo una version que mandaba game.GameId (el
-- universe id) creyendo que era lo que pedia el endpoint: no lo es, y la API
-- contesta 400 "The place is invalid." SIEMPRE. Comprobado contra la API:
--   place 109983668079237 -> 200, servers reales
--   universe   7709344486 -> 400, "The place is invalid."
-- Con eso, GetServerPage devolvia nil en cada intento y el hop no encontraba
-- nunca nada -- el sintoma que se veia como "ni hace hop" y que se atribuyo a
-- un rate-limit. No era rate-limit: era el id equivocado.
local function GetServerPage(Cursor)
    local Url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(TARGET_PLACE_ID)
    if Cursor and Cursor ~= "" then
        Url = Url .. "&cursor=" .. Cursor
    end
    local OK, Result = pcall(function()
        return HttpService:JSONDecode(game:HttpGet(Url))
    end)
    -- warn(), no print(): asi se distingue en la consola "la API esta
    -- fallando (rate-limit, red)" de "no hay servers chicos disponibles"
    -- (que simplemente termina en GlobalBest = nil sin ningun error).
    if not OK then
        warn("[HONEY TP] Hop: request to games.roblox.com failed -- " .. tostring(Result))
        return nil
    end
    return Result
end

-- Antes, si ningun server tenia <= HOP_MAX_PLAYERS, Best quedaba nil y
-- HopToSmallServer terminaba haciendo un Teleport SIN server destino -- eso
-- te manda a cualquier server que el matchmaker elija, no a uno con poca
-- gente. Ahora se guarda ademas el server con menos gente visto en la
-- busqueda (GlobalBest) como resultado si ninguno entro bajo el umbral, Y se
-- corta la busqueda apenas aparece un candidato aceptable en vez de agotar
-- las HOP_MAX_PAGES paginas buscando el "mejor" posible -- menos requests
-- por intento, menos chance de rate-limit.
local function FindSmallServer()
    local GlobalBest
    local Cursor = ""
    local Pages = 0
    -- tostring(...) de los dos lados: si por lo que sea uno llegara como tipo
    -- distinto (userdata/number) la comparacion directa nunca es true y el
    -- server actual se cuela como candidato -- con N=1 (somos el unico ahi)
    -- eso lo hace ganar casi siempre, que es como se ve "el hop me manda al
    -- mismo server".
    local CurrentJobId = tostring(game.JobId)
    repeat
        local Data = GetServerPage(Cursor)
        if not Data or not Data.data then break end
        for _, Server in ipairs(Data.data) do
            local N = Server.playing
            if N ~= nil and tostring(Server.id) ~= CurrentJobId then
                if not GlobalBest or N < GlobalBest.playing then GlobalBest = Server end
                if N <= HOP_MAX_PLAYERS then return Server end
            end
        end
        Cursor = Data.nextPageCursor or ""
        Pages = Pages + 1
        if Cursor ~= "" and Cursor ~= nil and Pages < HOP_MAX_PAGES then
            task.wait(0.2)
        end
    until Cursor == "" or Cursor == nil or Pages >= HOP_MAX_PAGES
    return GlobalBest
end

-- ------------------------------------------------------------
-- FETCHER: el pool de servers del panel
-- ------------------------------------------------------------
-- Cuando el panel tiene el fetcher prendido, el listado de servers ya lo
-- scrapeo el, en segundo plano, repartido entre proxies con IP rotativa. El
-- bot solo pide "dame un jobId" y se lleva uno RESERVADO para el: ninguna
-- otra cuenta recibe el mismo. Eso arregla dos cosas de una:
--   1. el rate-limit de games.roblox.com desaparece del lado del bot (con
--      varias cuentas paginando el listado cada 1.5s era inevitable), y
--   2. dos cuentas dejan de saltar al mismo server, que es lo que pasaba
--      cuando todas leian la misma primera pagina del listado.
-- Se piden de a varios y se van consumiendo de una cola local para no pegarle
-- al panel en cada reintento.
-- Todo adentro de un do...end: lo unico que sale al scope del chunk son campos
-- de Hop, que no cuentan contra el limite de 200 locales.
do
    local FETCH_BATCH = 5
    local Queue = {}

    -- La usa Hop.Drop para encolar el reemplazo que devuelve el panel.
    function Hop.Push(List)
        if type(List) ~= "table" then return end
        for _, Id in ipairs(List) do
            if type(Id) == "string" and Id ~= "" then
                table.insert(Queue, Id)
            end
        end
    end

    local function NextFromPool()
        if not Hop.Take then return nil end
        local Current = tostring(game.JobId)

        if #Queue == 0 then
            Hop.Push(Hop.Take(FETCH_BATCH))
        end

        while #Queue > 0 do
            local Id = table.remove(Queue, 1)
            if Id ~= Current then return Id end
        end
        return nil
    end

    -- Devuelve (JobId, Origen). Primero el fetcher; si el panel no esta, no
    -- tiene el fetcher prendido o el pool quedo vacio, cae al listado directo
    -- de Roblox (el camino de siempre) para que nada dependa de que el panel
    -- este vivo.
    function Hop.Pick()
        local Id = NextFromPool()
        if Id then return Id, "fetcher" end

        local Server = FindSmallServer()
        if Server and tostring(Server.id) ~= tostring(game.JobId) then
            return tostring(Server.id), "roblox"
        end
        return nil, nil
    end

    -- Un jobId del pool puede haberse llenado entre el scrape y el salto. Si el
    -- teleport falla, se le avisa al panel para que lo saque del pool (y no se
    -- lo pase a la proxima cuenta que pregunte) en vez de tragarse el error.
    function Hop.Teleport(JobId, Origen)
        local Conn
        Conn = TeleportService.TeleportInitFailed:Connect(function(Player, Result)
            if Player ~= LocalPlayer then return end
            warn("[HONEY TP] Hop: teleport rejected (" .. tostring(Result) .. ") -> " .. tostring(JobId))
            if Origen == "fetcher" and Hop.Drop then
                task.spawn(Hop.Drop, JobId)
            end
        end)

        pcall(function()
            TeleportService:TeleportToPlaceInstance(TARGET_PLACE_ID, JobId, LocalPlayer)
        end)

        -- Si el teleport prende, el script muere con el server y esto no llega
        -- a correr; si no prende, libera la conexion para que no se apilen.
        task.delay(8, function()
            if Conn then Conn:Disconnect() end
        end)
    end
end

-- TeleportToPlaceInstance/Teleport no avisan de forma confiable si el hop en
-- si fallo (throttle, hiccup de red, etc.) -- pcall solo atrapa un error de
-- Lua sincronico, no un teleport que arranca y no prende. La unica señal
-- real es "seguimos aca": si el loop sigue corriendo es porque el intento
-- anterior no nos saco del server, asi que reintenta hasta lograrlo en vez
-- de tirar la toalla despues de un solo intento.
local HOP_RETRY_WAIT = 1.5

-- Un Teleport SIN instancia especifica deja que el matchmaker de Roblox
-- elija, y en juegos con pocos servers activos eso puede devolverte al MISMO
-- server del que saliste -- exactamente el "me cambia al mismo server" que
-- se reporto. Ahora nunca se dispara un teleport sin Server.id confirmado
-- (y distinto al actual); si la busqueda no encuentra nada, se espera y se
-- reintenta la busqueda en vez de tirar un teleport a ciegas.
local function HopToSmallServer()
    while Config.Enabled and Config.AutoHop and MyToken == G.__HoneyTPRun do
        -- El evento se corto en mitad de la busqueda: volver arriba en vez de
        -- seguir saltando de server en server sin nada que juntar.
        if Bee.ShouldHold() then return end
        SetStatus("Looking for a small server...", Color3.fromRGB(255, 110, 110))
        local JobId, Origen = Hop.Pick()
        if JobId then
            Hop.Teleport(JobId, Origen)
        end
        task.wait(HOP_RETRY_WAIT)
    end
end

local ON_COLOR  = Color3.fromRGB(255, 180, 55)
local MUTED     = Color3.fromRGB(150, 142, 154)

local Running = false
local EmptyScans = 0
local EMPTY_SCANS_BEFORE_HOP = 6

-- ============================================================
-- ORDEN DE RECOLECCION -- en que orden se visitan las jarras del lote
-- ------------------------------------------------------------
-- ScanHoney recorre una tabla hash: el orden que devuelve no tiene ninguna
-- relacion con la posicion de las jarras, asi que hay que decidirlo aca. Hay
-- dos estrategias y se elige con Config.SweepRoute, porque no siempre gana la
-- misma: dependen de como quedan repartidas las jarras en el mapa.
--
--   Nearest (el de siempre) -- en cada paso elige la mas cercana a donde
--     estamos PARADOS AHORA. Reacciona a lo que aparece y a donde terminaste
--     realmente parado, pero es un greedy local: agarra la de al lado, y
--     despues la mejor opcion queda del otro lado del grupo. De ahi sale el
--     zigzag, y el recorrido total termina mas largo que si se planeaba.
--
--   Sweep -- ordena TODO el lote una sola vez, antes de arrancar a moverse:
--     barrido angular alrededor del centro del grupo (como las agujas del
--     reloj), rotado para empezar por la jarra mas cercana al jugador. Un
--     barrido angular nunca cruza el centro dos veces, asi que el recorrido
--     no puede volver sobre sus pasos: queda un tour por el perimetro, un
--     solo trazo. El costo es que el orden se fija al principio y no se
--     reacomoda si aparece una jarra nueva a mitad del recorrido.
--
-- Van en una tabla y no como dos funciones sueltas por el limite de 200
-- locales del chunk (ver el comentario de `Hop` arriba).
-- ============================================================
local Route = { }

-- Devuelve el indice de la mas cercana a FromPos, limpiando de paso las que
-- ya no existen. Lo llama el loop en CADA paso, por eso recalcula.
function Route.Nearest(List, FromPos)
    local BestIdx, BestDist
    local I = 1
    while I <= #List do
        local Honey = List[I]
        if not Honey.Parent then
            table.remove(List, I)
        else
            local Pos = HoneyPosition(Honey)
            if Pos then
                local Dist = (Pos - FromPos).Magnitude
                if not BestDist or Dist < BestDist then
                    BestDist, BestIdx = Dist, I
                end
            end
            I = I + 1
        end
    end
    return BestIdx
end

-- Devuelve la lista entera ya ordenada. Se llama UNA vez por lote.
function Route.Sweep(List, FromPos)
    local Positions, Valid = { }, { }
    local CenterX, CenterY, CenterZ, Count = 0, 0, 0, 0
    for _, Honey in ipairs(List) do
        if Honey.Parent then
            local Pos = HoneyPosition(Honey)
            if Pos then
                Positions[Honey] = Pos
                table.insert(Valid, Honey)
                CenterX, CenterY, CenterZ = CenterX + Pos.X, CenterY + Pos.Y, CenterZ + Pos.Z
                Count = Count + 1
            end
        end
    end
    -- Con dos o menos no hay recorrido que optimizar, pero igual conviene
    -- arrancar por la de al lado.
    if Count <= 2 then
        table.sort(Valid, function(A, B)
            return (Positions[A] - FromPos).Magnitude < (Positions[B] - FromPos).Magnitude
        end)
        return Valid
    end

    local Center = Vector3.new(CenterX / Count, CenterY / Count, CenterZ / Count)

    -- Angulo en el plano horizontal (X/Z): la altura no importa para decidir
    -- el orden del barrido, solo para el trazado que ya hace BuildRoute.
    local WithAngle = { }
    for _, Honey in ipairs(Valid) do
        local ToPos = Positions[Honey] - Center
        table.insert(WithAngle, { Honey = Honey, Angle = math.atan2(ToPos.Z, ToPos.X), Pos = Positions[Honey] })
    end
    table.sort(WithAngle, function(A, B) return A.Angle < B.Angle end)

    -- Sin esto el barrido siempre arrancaria en el mismo punto del circulo
    -- (angulo -pi) sin importar donde estemos parados, y el primer tramo
    -- terminaria siendo el salto mas largo de todo el recorrido.
    local StartIdx, StartDist = 1, math.huge
    for I, Entry in ipairs(WithAngle) do
        local Dist = (Entry.Pos - FromPos).Magnitude
        if Dist < StartDist then StartDist, StartIdx = Dist, I end
    end

    local N = #WithAngle
    local Out = { }
    for I = 0, N - 1 do
        Out[I + 1] = WithAngle[((StartIdx - 1 + I) % N) + 1].Honey
    end
    return Out
end

local function ProcessQueue()
    if Running then return end
    Running = true
    task.spawn(function()
        while Config.Enabled and MyToken == G.__HoneyTPRun do
            local Honeys = ScanHoney()

            -- Sin evento no hay nada que juntar ni sentido en cambiar de
            -- server: se espera y listo. El scan de arriba igual corre, y si
            -- aparece una jarra Bee.Refresh la ve y suelta el freno solo.
            if Bee.ShouldHold() then
                EmptyScans = 0
                SetStatus("Waiting for the Bee event...", MUTED)
                task.wait(1)
            elseif #Honeys > 0 then
                EmptyScans = 0
                if Config.SweepRoute then
                    -- Un solo calculo de orden para todo el lote: el recorrido
                    -- queda como un trazo unico en vez de zigzag (ver Route).
                    local Root = GetRoot()
                    if Root then Honeys = Route.Sweep(Honeys, Root.Position) end
                    while #Honeys > 0 do
                        if not Config.Enabled or MyToken ~= G.__HoneyTPRun then break end

                        -- Puede haber desaparecido (otra cuenta la agarro)
                        -- entre que se planeo el orden y que le toca el turno:
                        -- se descarta sin gastar un TP en el vacio.
                        local Honey = table.remove(Honeys, 1)
                        if Honey.Parent then
                            SetStatus(("Collecting (%d left)"):format(#Honeys), ON_COLOR)
                            CollectHoney(Honey)
                        end
                    end
                else
                    while #Honeys > 0 do
                        if not Config.Enabled or MyToken ~= G.__HoneyTPRun then break end

                        local Root = GetRoot()
                        if not Root then break end

                        local Idx = Route.Nearest(Honeys, Root.Position)
                        if not Idx then break end

                        local Honey = table.remove(Honeys, Idx)
                        SetStatus(("Collecting (%d left)"):format(#Honeys), ON_COLOR)
                        CollectHoney(Honey)
                    end
                end
            elseif Config.AutoHop then
                -- Un scan vacio puede ser el mapa todavia cargando; varios
                -- seguidos confirman que ya se recolecto todo lo que habia.
                EmptyScans = EmptyScans + 1
                if EmptyScans >= EMPTY_SCANS_BEFORE_HOP then
                    -- Si teleporta, el script muere aca y no vuelve. Si vuelve
                    -- es porque se apago el auto-hop o se corto el evento: el
                    -- ciclo sigue desde cero en vez de cortar el collector.
                    HopToSmallServer()
                    EmptyScans = 0
                end
                SetStatus(("All collected, hop in %d/%d"):format(EmptyScans, EMPTY_SCANS_BEFORE_HOP), MUTED)
                task.wait(0.5)
            else
                SetStatus("Waiting for Honey...", MUTED)
                task.wait(0.3)
            end
            task.wait(0.1)
        end
        Running = false
    end)
end

-- ============================================================
-- GUI
-- ============================================================
local Old = CoreGui:FindFirstChild("HoneyTPCollector") or PlayerGui:FindFirstChild("HoneyTPCollector")
if Old then pcall(function() Old:Destroy() end) end
if G.__HoneyTPGui then pcall(function() G.__HoneyTPGui:Destroy() end) end

local COLORS = {
    bg      = Color3.fromRGB(16, 13, 17),
    bgEdge  = Color3.fromRGB(27, 20, 15),
    card    = Color3.fromRGB(27, 22, 28),
    button  = Color3.fromRGB(34, 28, 34),
    accent  = Color3.fromRGB(255, 171, 33),
    accent2 = Color3.fromRGB(255, 214, 90),
    good    = Color3.fromRGB(102, 224, 141),
    bad     = Color3.fromRGB(255, 110, 110),
    off     = Color3.fromRGB(55, 48, 52),
    text    = Color3.fromRGB(246, 242, 250),
    muted   = MUTED,
    stroke  = Color3.fromRGB(58, 49, 54),
    cyan    = Color3.fromRGB(70, 210, 255),
}

local function Corner(Obj, R)
    local C = Instance.new("UICorner")
    C.CornerRadius = UDim.new(0, R or 8)
    C.Parent = Obj
    return C
end

local function Stroke(Obj, Color, Transparency, Thickness)
    local S = Instance.new("UIStroke")
    S.Color = Color or COLORS.stroke
    S.Transparency = Transparency == nil and 0.1 or Transparency
    S.Thickness = Thickness or 1.5
    S.Parent = Obj
    return S
end

local function Gradient(Obj, C1, C2, Rotation)
    local Grad = Instance.new("UIGradient")
    Grad.Color = ColorSequence.new(C1, C2)
    Grad.Rotation = Rotation or 0
    Grad.Parent = Obj
    return Grad
end

local function Tween(Obj, T, Props)
    TweenService:Create(Obj, TweenInfo.new(T, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), Props):Play()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HoneyTPCollector"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 10000
pcall(function() if syn and syn.protect_gui then syn.protect_gui(ScreenGui) end end)
pcall(function() if protectgui then protectgui(ScreenGui) end end)

local Parent
pcall(function() Parent = gethui and gethui() end)
if not Parent then pcall(function() Parent = CoreGui end) end
if not Parent then Parent = PlayerGui end
ScreenGui.Parent = Parent
G.__HoneyTPGui = ScreenGui

local BASE_WIDTH, BASE_HEIGHT = 280, 436

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Position = UDim2.fromScale(0.5, 0.5)
Main.Size = UDim2.fromOffset(BASE_WIDTH, BASE_HEIGHT)
Main.BackgroundColor3 = COLORS.bg
Main.BorderSizePixel = 0
Main.Active = true
Main.Parent = ScreenGui
Corner(Main, 20)
Gradient(Main, COLORS.bg, COLORS.bgEdge, 60)
Stroke(Main, COLORS.accent, 0.72, 1.4)

-- Header: icon badge + title/subtitle + minimize
local Header = Instance.new("Frame")
Header.Name = "DragHeader"
Header.Size = UDim2.new(1, 0, 0, 58)
Header.BackgroundTransparency = 1
Header.Active = true
Header.Parent = Main

local IconBadge = Instance.new("Frame")
IconBadge.Position = UDim2.fromOffset(16, 14)
IconBadge.Size = UDim2.fromOffset(32, 32)
IconBadge.BackgroundColor3 = COLORS.accent
IconBadge.BorderSizePixel = 0
IconBadge.Parent = Header
Corner(IconBadge, 10)
Gradient(IconBadge, COLORS.accent, COLORS.accent2, 45)

local IconText = Instance.new("TextLabel")
IconText.Size = UDim2.fromScale(1, 1)
IconText.BackgroundTransparency = 1
IconText.Text = "🍯"
IconText.TextSize = 16
IconText.Font = Enum.Font.GothamBold
IconText.Parent = IconBadge

local Title = Instance.new("TextLabel")
Title.Position = UDim2.fromOffset(58, 13)
Title.Size = UDim2.new(1, -108, 0, 18)
Title.BackgroundTransparency = 1
Title.Text = "Honey TP"
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.TextColor3 = COLORS.text
Title.Font = Enum.Font.GothamBold
Title.TextSize = 15
Title.Parent = Header

local Subtitle = Instance.new("TextLabel")
Subtitle.Position = UDim2.fromOffset(58, 32)
Subtitle.Size = UDim2.new(1, -108, 0, 14)
Subtitle.BackgroundTransparency = 1
Subtitle.Text = "Collector"
Subtitle.TextXAlignment = Enum.TextXAlignment.Left
Subtitle.TextColor3 = COLORS.muted
Subtitle.Font = Enum.Font.GothamMedium
Subtitle.TextSize = 10
Subtitle.Parent = Header

local MinimizeButton = Instance.new("TextButton")
MinimizeButton.AnchorPoint = Vector2.new(1, 0)
MinimizeButton.Position = UDim2.new(1, -14, 0, 14)
MinimizeButton.Size = UDim2.fromOffset(28, 28)
MinimizeButton.BackgroundColor3 = COLORS.button
MinimizeButton.BorderSizePixel = 0
MinimizeButton.AutoButtonColor = false
MinimizeButton.Text = utf8.char(0x2212)
MinimizeButton.TextColor3 = COLORS.accent
MinimizeButton.TextSize = 16
MinimizeButton.Font = Enum.Font.GothamBold
MinimizeButton.Parent = Header
Corner(MinimizeButton, 9)
Stroke(MinimizeButton, COLORS.stroke, 0.4, 1)

-- Divider with a soft fade at both ends
local Divider = Instance.new("Frame")
Divider.Position = UDim2.fromOffset(16, 58)
Divider.Size = UDim2.new(1, -32, 0, 2)
Divider.BackgroundColor3 = COLORS.accent
Divider.BorderSizePixel = 0
Divider.Parent = Main
Corner(Divider, 1)
local DividerGrad = Gradient(Divider, COLORS.accent, COLORS.accent2, 0)
DividerGrad.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.65),
    NumberSequenceKeypoint.new(0.5, 0),
    NumberSequenceKeypoint.new(1, 0.65),
})

-- Reusable switch row (card + label [+ sublabel] + pill toggle). ParentFrame
-- lets the same builder drop a switch into the popover, not just Main.
local function MakeSwitchRow(ParentFrame, Y, Height, Label, SubLabel)
    local Row = Instance.new("Frame")
    Row.Position = UDim2.fromOffset(16, Y)
    Row.Size = UDim2.new(1, -32, 0, Height)
    Row.BackgroundColor3 = COLORS.card
    Row.BorderSizePixel = 0
    Row.Parent = ParentFrame
    Corner(Row, 12)
    Stroke(Row, COLORS.stroke, 0.5, 1)

    local Lbl = Instance.new("TextLabel")
    Lbl.Position = UDim2.fromOffset(14, SubLabel and 8 or 0)
    Lbl.Size = UDim2.new(1, -76, 0, SubLabel and 16 or Height)
    Lbl.BackgroundTransparency = 1
    Lbl.Text = Label
    Lbl.TextXAlignment = Enum.TextXAlignment.Left
    Lbl.TextYAlignment = Enum.TextYAlignment.Center
    Lbl.TextColor3 = COLORS.text
    Lbl.Font = Enum.Font.GothamBold
    Lbl.TextSize = 12
    Lbl.Parent = Row

    if SubLabel then
        local Sub = Instance.new("TextLabel")
        Sub.Position = UDim2.fromOffset(14, 26)
        Sub.Size = UDim2.new(1, -76, 0, 24)
        Sub.BackgroundTransparency = 1
        Sub.Text = SubLabel
        Sub.TextWrapped = true
        Sub.TextXAlignment = Enum.TextXAlignment.Left
        Sub.TextYAlignment = Enum.TextYAlignment.Top
        Sub.TextColor3 = COLORS.muted
        Sub.Font = Enum.Font.Gotham
        Sub.TextSize = 9
        Sub.Parent = Row
    end

    local Track = Instance.new("Frame")
    Track.AnchorPoint = Vector2.new(1, 0.5)
    Track.Position = UDim2.new(1, -14, 0.5, 0)
    Track.Size = UDim2.fromOffset(46, 24)
    Track.BackgroundColor3 = COLORS.off
    Track.BorderSizePixel = 0
    Track.Parent = Row
    Corner(Track, 12)

    local Knob = Instance.new("Frame")
    Knob.Size = UDim2.fromOffset(18, 18)
    Knob.Position = UDim2.fromOffset(3, 3)
    Knob.BackgroundColor3 = Color3.fromRGB(250, 250, 253)
    Knob.BorderSizePixel = 0
    Knob.Parent = Track
    Corner(Knob, 9)

    local Hit = Instance.new("TextButton")
    Hit.Size = UDim2.fromScale(1, 1)
    Hit.BackgroundTransparency = 1
    Hit.Text = ""
    Hit.Parent = Track

    return Track, Knob, Hit
end

-- Auto Collect
local AUTO_ROW_Y = 70
local AutoTrack, AutoKnob, AutoHit = MakeSwitchRow(Main, AUTO_ROW_Y, 44, "Auto Collect")

-- TP Method (Grapple / Carpet)
local METHOD_LABEL_Y = 124
local METHOD_BTN_Y = 140

local MethodLabel = Instance.new("TextLabel")
MethodLabel.Position = UDim2.fromOffset(16, METHOD_LABEL_Y)
MethodLabel.Size = UDim2.new(1, -32, 0, 14)
MethodLabel.BackgroundTransparency = 1
MethodLabel.Text = "TP METHOD"
MethodLabel.TextXAlignment = Enum.TextXAlignment.Left
MethodLabel.TextColor3 = COLORS.muted
MethodLabel.Font = Enum.Font.GothamBold
MethodLabel.TextSize = 10
MethodLabel.Parent = Main

local METHODS = {
    {id = "Grapple", label = "GRAPPLE", icon = "🪝"},
    {id = "Carpet",  label = "CARPET",  icon = "🧺"},
}

local METHOD_BTN_W = (BASE_WIDTH - 32 - 10) / 2
local MethodButtons = { }
local PaintMethods

for Index, Info in ipairs(METHODS) do
    local Button = Instance.new("TextButton")
    Button.Position = UDim2.fromOffset(16 + (Index - 1) * (METHOD_BTN_W + 10), METHOD_BTN_Y)
    Button.Size = UDim2.fromOffset(METHOD_BTN_W, 42)
    Button.BackgroundColor3 = COLORS.button
    Button.BorderSizePixel = 0
    Button.AutoButtonColor = false
    Button.Text = ""
    Button.Parent = Main
    Corner(Button, 12)
    local Strk = Stroke(Button, COLORS.stroke, 0.5, 1)
    local Grad = Gradient(Button, COLORS.accent, COLORS.accent2, 45)
    Grad.Enabled = false

    local Lbl = Instance.new("TextLabel")
    Lbl.Size = UDim2.fromScale(1, 1)
    Lbl.BackgroundTransparency = 1
    Lbl.Text = Info.icon .. "  " .. Info.label
    Lbl.TextColor3 = COLORS.muted
    Lbl.Font = Enum.Font.GothamBold
    Lbl.TextSize = 12
    Lbl.Parent = Button

    Button.Activated:Connect(function()
        Config.Method = Info.id
        Cancel = true
        task.delay(0.1, function() Cancel = false end)
        SaveConfig()
        PaintMethods()
    end)
    MethodButtons[Info.id] = { Frame = Button, Grad = Grad, Label = Lbl, Stroke = Strk }
end

PaintMethods = function()
    for Id, B in pairs(MethodButtons) do
        local Selected = Config.Method == Id
        Tween(B.Frame, 0.12, {BackgroundColor3 = Selected and COLORS.accent or COLORS.button})
        B.Grad.Enabled = Selected
        B.Label.TextColor3 = Selected and Color3.fromRGB(32, 22, 8) or COLORS.muted
        B.Stroke.Transparency = Selected and 1 or 0.5
    end
end

-- ============================================================
-- SMART TP -- boton que abre un popover con el toggle adentro.
-- ------------------------------------------------------------
-- El gancho tiene cooldown propio (~3s) y sirve para tramos largos (~700
-- studs); en tramos cortos, o mientras esta en cooldown, la carpet sola ya
-- llega bien hasta ~300 studs. Prendido, MoveToPosition elige el metodo por
-- si solo en cada TP en vez de forzar siempre el mismo -- ver SmartPickMethod.
-- ============================================================
local SMART_BTN_Y = 192

local SmartBtn = Instance.new("TextButton")
SmartBtn.Position = UDim2.fromOffset(16, SMART_BTN_Y)
SmartBtn.Size = UDim2.new(1, -32, 0, 32)
SmartBtn.BackgroundColor3 = COLORS.card
SmartBtn.BorderSizePixel = 0
SmartBtn.AutoButtonColor = false
SmartBtn.Text = ""
SmartBtn.Parent = Main
Corner(SmartBtn, 10)
local SmartBtnStroke = Stroke(SmartBtn, COLORS.stroke, 0.5, 1)

local SmartBtnLabel = Instance.new("TextLabel")
SmartBtnLabel.Position = UDim2.fromOffset(12, 0)
SmartBtnLabel.Size = UDim2.new(1, -64, 1, 0)
SmartBtnLabel.BackgroundTransparency = 1
SmartBtnLabel.Text = "🧠 Smart TP"
SmartBtnLabel.TextXAlignment = Enum.TextXAlignment.Left
SmartBtnLabel.TextColor3 = COLORS.text
SmartBtnLabel.Font = Enum.Font.GothamBold
SmartBtnLabel.TextSize = 11
SmartBtnLabel.Parent = SmartBtn

local SmartBtnState = Instance.new("TextLabel")
SmartBtnState.AnchorPoint = Vector2.new(1, 0.5)
SmartBtnState.Position = UDim2.new(1, -26, 0.5, 0)
SmartBtnState.Size = UDim2.fromOffset(44, 16)
SmartBtnState.BackgroundTransparency = 1
SmartBtnState.Text = "OFF"
SmartBtnState.TextXAlignment = Enum.TextXAlignment.Right
SmartBtnState.Font = Enum.Font.GothamBold
SmartBtnState.TextSize = 9
SmartBtnState.Parent = SmartBtn

local SmartChevron = Instance.new("TextLabel")
SmartChevron.AnchorPoint = Vector2.new(1, 0.5)
SmartChevron.Position = UDim2.new(1, -10, 0.5, 0)
SmartChevron.Size = UDim2.fromOffset(14, 14)
SmartChevron.BackgroundTransparency = 1
SmartChevron.Text = utf8.char(0x203A)
SmartChevron.TextColor3 = COLORS.muted
SmartChevron.Font = Enum.Font.GothamBold
SmartChevron.TextSize = 14
SmartChevron.Parent = SmartBtn

-- Popover: overlay de fondo (cierra al tocar afuera) + tarjeta con el toggle.
local SmartOverlay = Instance.new("TextButton")
SmartOverlay.Size = UDim2.fromScale(1, 1)
SmartOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
SmartOverlay.BackgroundTransparency = 0.45
SmartOverlay.AutoButtonColor = false
SmartOverlay.Text = ""
SmartOverlay.Visible = false
SmartOverlay.ZIndex = 5
SmartOverlay.Parent = ScreenGui

local SmartPopup = Instance.new("Frame")
SmartPopup.AnchorPoint = Vector2.new(0.5, 0.5)
SmartPopup.Position = UDim2.fromScale(0.5, 0.5)
SmartPopup.Size = UDim2.fromOffset(240, 312)
SmartPopup.BackgroundColor3 = COLORS.bg
SmartPopup.BorderSizePixel = 0
SmartPopup.Active = true -- absorbe el click para que no cierre el popup por error
SmartPopup.ZIndex = 6
SmartPopup.Parent = SmartOverlay
Corner(SmartPopup, 16)
Gradient(SmartPopup, COLORS.bg, COLORS.bgEdge, 60)
Stroke(SmartPopup, COLORS.accent, 0.6, 1.4)

local SmartPopupTitle = Instance.new("TextLabel")
SmartPopupTitle.Position = UDim2.fromOffset(16, 14)
SmartPopupTitle.Size = UDim2.new(1, -60, 0, 18)
SmartPopupTitle.BackgroundTransparency = 1
SmartPopupTitle.Text = "🧠 Smart TP"
SmartPopupTitle.TextXAlignment = Enum.TextXAlignment.Left
SmartPopupTitle.TextColor3 = COLORS.text
SmartPopupTitle.Font = Enum.Font.GothamBold
SmartPopupTitle.TextSize = 13
SmartPopupTitle.Parent = SmartPopup

local SmartCloseBtn = Instance.new("TextButton")
SmartCloseBtn.AnchorPoint = Vector2.new(1, 0)
SmartCloseBtn.Position = UDim2.new(1, -12, 0, 12)
SmartCloseBtn.Size = UDim2.fromOffset(24, 24)
SmartCloseBtn.BackgroundColor3 = COLORS.button
SmartCloseBtn.BorderSizePixel = 0
SmartCloseBtn.AutoButtonColor = false
SmartCloseBtn.Text = utf8.char(0x2715)
SmartCloseBtn.TextColor3 = COLORS.muted
SmartCloseBtn.TextSize = 11
SmartCloseBtn.Font = Enum.Font.GothamBold
SmartCloseBtn.Parent = SmartPopup
Corner(SmartCloseBtn, 8)

local SmartDesc = Instance.new("TextLabel")
SmartDesc.Position = UDim2.fromOffset(16, 38)
SmartDesc.Size = UDim2.new(1, -32, 0, 40)
SmartDesc.BackgroundTransparency = 1
SmartDesc.Text = "Usa Grapple siempre que se pueda (listo y dentro de rango); si no, cae a Carpet."
SmartDesc.TextWrapped = true
SmartDesc.TextXAlignment = Enum.TextXAlignment.Left
SmartDesc.TextYAlignment = Enum.TextYAlignment.Top
SmartDesc.TextColor3 = COLORS.muted
SmartDesc.Font = Enum.Font.Gotham
SmartDesc.TextSize = 10
SmartDesc.Parent = SmartPopup

local SmartTrack, SmartKnob, SmartHit = MakeSwitchRow(SmartPopup, 84, 40, "Smart Mode")

-- Se arma en funcion, no en constante, porque los umbrales viven en Config y
-- pueden cambiar en caliente (desde el panel): PaintSmart lo vuelve a pedir.
local function SmartCaptionText()
    return ("Gancho: siempre que este listo (cooldown %ds), sin importar la distancia · Carpet a %d si no hay gancho disponible"):format(
        GRAPPLE_COOLDOWN, Config.SmartFallbackSpeed)
end

local SmartCaption = Instance.new("TextLabel")
SmartCaption.Position = UDim2.fromOffset(16, 176)
SmartCaption.Size = UDim2.new(1, -32, 0, 44)
SmartCaption.BackgroundTransparency = 1
SmartCaption.Text = SmartCaptionText()
SmartCaption.TextWrapped = true
SmartCaption.TextXAlignment = Enum.TextXAlignment.Left
SmartCaption.TextYAlignment = Enum.TextYAlignment.Top
SmartCaption.TextColor3 = COLORS.muted
SmartCaption.TextTransparency = 0.25
SmartCaption.Font = Enum.Font.Gotham
SmartCaption.TextSize = 9
SmartCaption.Parent = SmartPopup

-- Selector de orden de recolección, dentro del mismo popover porque es la otra
-- mitad de "como se mueve el collector": Smart TP elige COMO viajar a cada
-- jarra, esto elige EN QUE ORDEN. Va en do..end y la funcion de pintado cuelga
-- de Route para no sumar locales al chunk (tope de 200, ver `Hop`).
do
    local SweepLabel = Instance.new("TextLabel")
    SweepLabel.Position = UDim2.fromOffset(16, 226)
    SweepLabel.Size = UDim2.new(1, -32, 0, 14)
    SweepLabel.BackgroundTransparency = 1
    SweepLabel.Text = "COLLECT ORDER"
    SweepLabel.TextXAlignment = Enum.TextXAlignment.Left
    SweepLabel.TextColor3 = COLORS.muted
    SweepLabel.Font = Enum.Font.GothamBold
    SweepLabel.TextSize = 10
    SweepLabel.Parent = SmartPopup

    local Track, Knob, Hit = MakeSwitchRow(SmartPopup, 244, 52, "Single sweep",
        "Un solo recorrido planeado de una. Apagado: la mas cercana en cada paso (zigzag).")

    function Route.Paint()
        if Config.SweepRoute then
            Tween(Track, 0.15, { BackgroundColor3 = COLORS.good })
            Tween(Knob, 0.15, { Position = UDim2.fromOffset(25, 3) })
        else
            Tween(Track, 0.15, { BackgroundColor3 = COLORS.off })
            Tween(Knob, 0.15, { Position = UDim2.fromOffset(3, 3) })
        end
    end

    Hit.Activated:Connect(function()
        Config.SweepRoute = not Config.SweepRoute
        SaveConfig()
        Route.Paint()
    end)
end

local function PaintSmart()
    SmartCaption.Text = SmartCaptionText()
    Route.Paint()
    SmartBtnState.TextColor3 = Config.SmartTP and COLORS.good or COLORS.muted
    SmartBtnState.Text = Config.SmartTP and "ON" or "OFF"
    SmartBtnStroke.Color = Config.SmartTP and COLORS.accent or COLORS.stroke
    SmartBtnStroke.Transparency = Config.SmartTP and 0.4 or 0.5
    if Config.SmartTP then
        Tween(SmartTrack, 0.15, {BackgroundColor3 = COLORS.good})
        Tween(SmartKnob, 0.15, {Position = UDim2.fromOffset(25, 3)})
    else
        Tween(SmartTrack, 0.15, {BackgroundColor3 = COLORS.off})
        Tween(SmartKnob, 0.15, {Position = UDim2.fromOffset(3, 3)})
    end
end

SmartHit.Activated:Connect(function()
    Config.SmartTP = not Config.SmartTP
    SaveConfig()
    PaintSmart()
end)

-- Velocidad de Carpet cuando el gancho esta en cooldown -- configurable con
-- su propio slider, igual que TP Speed, en vez de un valor fijo que solo se
-- podia tocar editando honey_tp.json a mano. Va en un do..end para no sumar
-- locales permanentes de mas: el chunk principal tiene un tope duro de 200
-- variables locales activas, y este script ya anda cerca del limite.
local SmartSpeedDragging = false
local SyncSmartSpeedDisplay, SetSmartSpeedFromX

do
    local SmartSpeedLabel = Instance.new("TextLabel")
    SmartSpeedLabel.Position = UDim2.fromOffset(16, 134)
    SmartSpeedLabel.Size = UDim2.new(0.6, -16, 0, 14)
    SmartSpeedLabel.BackgroundTransparency = 1
    SmartSpeedLabel.Text = "CARPET FALLBACK SPEED"
    SmartSpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
    SmartSpeedLabel.TextColor3 = COLORS.muted
    SmartSpeedLabel.Font = Enum.Font.GothamBold
    SmartSpeedLabel.TextSize = 10
    SmartSpeedLabel.Parent = SmartPopup

    local SmartSpeedValue = Instance.new("TextLabel")
    SmartSpeedValue.AnchorPoint = Vector2.new(1, 0)
    SmartSpeedValue.Position = UDim2.new(1, -16, 0, 134)
    SmartSpeedValue.Size = UDim2.fromOffset(90, 14)
    SmartSpeedValue.BackgroundTransparency = 1
    SmartSpeedValue.TextXAlignment = Enum.TextXAlignment.Right
    SmartSpeedValue.TextColor3 = COLORS.accent2
    SmartSpeedValue.Font = Enum.Font.GothamBold
    SmartSpeedValue.TextSize = 10
    SmartSpeedValue.Parent = SmartPopup

    local SmartSpeedTrack = Instance.new("Frame")
    SmartSpeedTrack.Position = UDim2.fromOffset(16, 152)
    SmartSpeedTrack.Size = UDim2.new(1, -32, 0, 10)
    SmartSpeedTrack.BackgroundColor3 = COLORS.button
    SmartSpeedTrack.BorderSizePixel = 0
    SmartSpeedTrack.Active = true
    SmartSpeedTrack.Parent = SmartPopup
    Corner(SmartSpeedTrack, 99)

    local SmartSpeedFill = Instance.new("Frame")
    SmartSpeedFill.Size = UDim2.new(0, 0, 1, 0)
    SmartSpeedFill.BackgroundColor3 = COLORS.accent
    SmartSpeedFill.BorderSizePixel = 0
    SmartSpeedFill.Parent = SmartSpeedTrack
    Corner(SmartSpeedFill, 99)
    Gradient(SmartSpeedFill, COLORS.accent, COLORS.accent2, 0)

    local SmartSpeedKnob = Instance.new("Frame")
    SmartSpeedKnob.AnchorPoint = Vector2.new(0.5, 0.5)
    SmartSpeedKnob.Position = UDim2.new(0, 0, 0.5, 0)
    SmartSpeedKnob.Size = UDim2.fromOffset(16, 16)
    SmartSpeedKnob.BackgroundColor3 = Color3.fromRGB(250, 250, 253)
    SmartSpeedKnob.BorderSizePixel = 0
    SmartSpeedKnob.Active = true
    SmartSpeedKnob.ZIndex = 2
    SmartSpeedKnob.Parent = SmartSpeedTrack
    Corner(SmartSpeedKnob, 99)
    Stroke(SmartSpeedKnob, COLORS.accent, 0.3, 1.4)

    local SMART_SPEED_MIN, SMART_SPEED_MAX = 50, 1000

    SyncSmartSpeedDisplay = function()
        local Speed = math.floor(math.clamp(Config.SmartFallbackSpeed, SMART_SPEED_MIN, SMART_SPEED_MAX) + 0.5)
        Config.SmartFallbackSpeed = Speed
        local Alpha = (Speed - SMART_SPEED_MIN) / (SMART_SPEED_MAX - SMART_SPEED_MIN)
        SmartSpeedFill.Size = UDim2.new(Alpha, 0, 1, 0)
        SmartSpeedKnob.Position = UDim2.new(Alpha, 0, 0.5, 0)
        SmartSpeedValue.Text = tostring(Speed) .. " studs/s"
        SmartCaption.Text = SmartCaptionText()
    end

    SetSmartSpeedFromX = function(X, ShouldSave)
        local Width = math.max(SmartSpeedTrack.AbsoluteSize.X, 1)
        local Alpha = math.clamp((X - SmartSpeedTrack.AbsolutePosition.X) / Width, 0, 1)
        Config.SmartFallbackSpeed = math.floor(SMART_SPEED_MIN + Alpha * (SMART_SPEED_MAX - SMART_SPEED_MIN) + 0.5)
        SyncSmartSpeedDisplay()
        if ShouldSave then SaveConfig() end
    end

    local function BeginSmartSpeedDrag(Input)
        SmartSpeedDragging = true
        SetSmartSpeedFromX(Input.Position.X, false)
    end

    SmartSpeedTrack.InputBegan:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1
            or Input.UserInputType == Enum.UserInputType.Touch then
            BeginSmartSpeedDrag(Input)
        end
    end)
    SmartSpeedKnob.InputBegan:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1
            or Input.UserInputType == Enum.UserInputType.Touch then
            BeginSmartSpeedDrag(Input)
        end
    end)
end

SmartBtn.Activated:Connect(function() SmartOverlay.Visible = true end)
SmartCloseBtn.Activated:Connect(function() SmartOverlay.Visible = false end)
SmartOverlay.Activated:Connect(function() SmartOverlay.Visible = false end)

-- Coordenadas de las filas del panel, juntas en una tabla y no como locals
-- sueltos: el chunk esta al filo del limite de 200 variables locales de Lua
-- (ver el comentario de `Hop` arriba), y los campos de una tabla no cuentan.
local Layout = {
    speedLabel = 236,
    speedTrack = 254,
    hopRow     = 280,
    chips      = 346,
    status     = 386,
    chipW      = (BASE_WIDTH - 32 - 10) / 2,
}

-- TP Speed
local SpeedLabel = Instance.new("TextLabel")
SpeedLabel.Position = UDim2.fromOffset(16, Layout.speedLabel)
SpeedLabel.Size = UDim2.new(0.6, -16, 0, 14)
SpeedLabel.BackgroundTransparency = 1
SpeedLabel.Text = "TP SPEED"
SpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
SpeedLabel.TextColor3 = COLORS.muted
SpeedLabel.Font = Enum.Font.GothamBold
SpeedLabel.TextSize = 10
SpeedLabel.Parent = Main

local SpeedValue = Instance.new("TextLabel")
SpeedValue.AnchorPoint = Vector2.new(1, 0)
SpeedValue.Position = UDim2.new(1, -16, 0, Layout.speedLabel)
SpeedValue.Size = UDim2.fromOffset(90, 14)
SpeedValue.BackgroundTransparency = 1
SpeedValue.TextXAlignment = Enum.TextXAlignment.Right
SpeedValue.TextColor3 = COLORS.accent2
SpeedValue.Font = Enum.Font.GothamBold
SpeedValue.TextSize = 10
SpeedValue.Parent = Main

local SpeedTrack = Instance.new("Frame")
SpeedTrack.Position = UDim2.fromOffset(16, Layout.speedTrack)
SpeedTrack.Size = UDim2.new(1, -32, 0, 10)
SpeedTrack.BackgroundColor3 = COLORS.button
SpeedTrack.BorderSizePixel = 0
SpeedTrack.Active = true
SpeedTrack.Parent = Main
Corner(SpeedTrack, 99)

local SpeedFill = Instance.new("Frame")
SpeedFill.Size = UDim2.new(0, 0, 1, 0)
SpeedFill.BackgroundColor3 = COLORS.accent
SpeedFill.BorderSizePixel = 0
SpeedFill.Parent = SpeedTrack
Corner(SpeedFill, 99)
Gradient(SpeedFill, COLORS.accent, COLORS.accent2, 0)

local SpeedKnob = Instance.new("Frame")
SpeedKnob.AnchorPoint = Vector2.new(0.5, 0.5)
SpeedKnob.Position = UDim2.new(0, 0, 0.5, 0)
SpeedKnob.Size = UDim2.fromOffset(16, 16)
SpeedKnob.BackgroundColor3 = Color3.fromRGB(250, 250, 253)
SpeedKnob.BorderSizePixel = 0
SpeedKnob.Active = true
SpeedKnob.ZIndex = 2
SpeedKnob.Parent = SpeedTrack
Corner(SpeedKnob, 99)
Stroke(SpeedKnob, COLORS.accent, 0.3, 1.4)

local SPEED_MIN, SPEED_MAX = 50, 1000
local SpeedDragging = false

local function SyncSpeedDisplay()
    local Speed = math.floor(math.clamp(Config.Speed, SPEED_MIN, SPEED_MAX) + 0.5)
    Config.Speed = Speed
    local Alpha = (Speed - SPEED_MIN) / (SPEED_MAX - SPEED_MIN)
    SpeedFill.Size = UDim2.new(Alpha, 0, 1, 0)
    SpeedKnob.Position = UDim2.new(Alpha, 0, 0.5, 0)
    SpeedValue.Text = tostring(Speed) .. " studs/s"
end

local function SetSpeedFromX(X, ShouldSave)
    local Width = math.max(SpeedTrack.AbsoluteSize.X, 1)
    local Alpha = math.clamp((X - SpeedTrack.AbsolutePosition.X) / Width, 0, 1)
    Config.Speed = math.floor(SPEED_MIN + Alpha * (SPEED_MAX - SPEED_MIN) + 0.5)
    SyncSpeedDisplay()
    if ShouldSave then SaveConfig() end
end

local function BeginSpeedDrag(Input)
    SpeedDragging = true
    SetSpeedFromX(Input.Position.X, false)
end

SpeedTrack.InputBegan:Connect(function(Input)
    if Input.UserInputType == Enum.UserInputType.MouseButton1
        or Input.UserInputType == Enum.UserInputType.Touch then
        BeginSpeedDrag(Input)
    end
end)
SpeedKnob.InputBegan:Connect(function(Input)
    if Input.UserInputType == Enum.UserInputType.MouseButton1
        or Input.UserInputType == Enum.UserInputType.Touch then
        BeginSpeedDrag(Input)
    end
end)

-- Auto Hop After Collect
local HopTrack, HopKnob, HopHit = MakeSwitchRow(Main, Layout.hopRow, 56, "Auto Hop After Collect",
    "Hops to a low-pop server once this one's empty")

local function PaintHop()
    if Config.AutoHop then
        Tween(HopTrack, 0.15, {BackgroundColor3 = COLORS.good})
        Tween(HopKnob, 0.15, {Position = UDim2.fromOffset(25, 3)})
    else
        Tween(HopTrack, 0.15, {BackgroundColor3 = COLORS.off})
        Tween(HopKnob, 0.15, {Position = UDim2.fromOffset(3, 3)})
    end
end

HopHit.Activated:Connect(function()
    Config.AutoHop = not Config.AutoHop
    SaveConfig()
    PaintHop()
end)

-- Chips: Health Lock / Show Path
local function MakeChip(X, Label)
    local Chip = Instance.new("TextButton")
    Chip.Position = UDim2.fromOffset(X, Layout.chips)
    Chip.Size = UDim2.fromOffset(Layout.chipW, 30)
    Chip.BackgroundColor3 = COLORS.card
    Chip.BorderSizePixel = 0
    Chip.AutoButtonColor = false
    Chip.Text = ""
    Chip.Parent = Main
    Corner(Chip, 10)
    Stroke(Chip, COLORS.stroke, 0.5, 1)

    local Dot = Instance.new("Frame")
    Dot.AnchorPoint = Vector2.new(0, 0.5)
    Dot.Position = UDim2.fromOffset(10, 15)
    Dot.Size = UDim2.fromOffset(7, 7)
    Dot.BackgroundColor3 = COLORS.off
    Dot.BorderSizePixel = 0
    Dot.Parent = Chip
    Corner(Dot, 4)

    local Lbl = Instance.new("TextLabel")
    Lbl.Position = UDim2.fromOffset(24, 0)
    Lbl.Size = UDim2.new(1, -30, 1, 0)
    Lbl.BackgroundTransparency = 1
    Lbl.Text = Label
    Lbl.TextXAlignment = Enum.TextXAlignment.Left
    Lbl.TextColor3 = COLORS.muted
    Lbl.Font = Enum.Font.GothamMedium
    Lbl.TextSize = 10
    Lbl.Parent = Chip

    return Chip, Dot, Lbl
end

local HealthChip, HealthDot, HealthLbl = MakeChip(16, "Health Lock")
local PathChip, PathDot, PathLbl = MakeChip(16 + Layout.chipW + 10, "Show Path")

local function PaintHealth()
    local On = Config.HealthLock
    Tween(HealthDot, 0.12, {BackgroundColor3 = On and COLORS.bad or COLORS.off})
    HealthLbl.TextColor3 = On and Color3.fromRGB(255, 160, 160) or COLORS.muted
end

HealthChip.Activated:Connect(function()
    Config.HealthLock = not Config.HealthLock
    SaveConfig()
    PaintHealth()
end)

local function PaintShowPath()
    local On = G.honeyTPShowPath ~= false
    Tween(PathDot, 0.12, {BackgroundColor3 = On and COLORS.cyan or COLORS.off})
    PathLbl.TextColor3 = On and Color3.fromRGB(160, 225, 255) or COLORS.muted
end

PathChip.Activated:Connect(function()
    G.honeyTPShowPath = G.honeyTPShowPath == false and true or false
    if G.honeyTPShowPath == false then clearViz() end
    PaintShowPath()
end)

-- Status + collected counter
local StatusDot = Instance.new("Frame")
StatusDot.AnchorPoint = Vector2.new(0, 0.5)
StatusDot.Position = UDim2.fromOffset(16, Layout.status + 8)
StatusDot.Size = UDim2.fromOffset(7, 7)
StatusDot.BackgroundColor3 = COLORS.muted
StatusDot.BorderSizePixel = 0
StatusDot.Parent = Main
Corner(StatusDot, 4)

local Status = Instance.new("TextLabel")
Status.Position = UDim2.fromOffset(28, Layout.status)
Status.Size = UDim2.new(1, -100, 0, 16)
Status.BackgroundTransparency = 1
Status.Text = "Idle"
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.TextColor3 = COLORS.muted
Status.Font = Enum.Font.Gotham
Status.TextSize = 10
Status.TextTruncate = Enum.TextTruncate.AtEnd
Status.Parent = Main

local CollectedLabel = Instance.new("TextLabel")
CollectedLabel.AnchorPoint = Vector2.new(1, 0)
CollectedLabel.Position = UDim2.new(1, -16, 0, Layout.status)
CollectedLabel.Size = UDim2.fromOffset(60, 16)
CollectedLabel.BackgroundTransparency = 1
CollectedLabel.Text = "🍯 0"
CollectedLabel.TextXAlignment = Enum.TextXAlignment.Right
CollectedLabel.TextColor3 = COLORS.accent2
CollectedLabel.Font = Enum.Font.GothamBold
CollectedLabel.TextSize = 10
CollectedLabel.Parent = Main

SetStatus = function(Text, Color)
    if not Status.Parent then return end
    Status.Text = Text
    Tween(Status, 0.15, {TextColor3 = Color or COLORS.muted})
    Tween(StatusDot, 0.15, {BackgroundColor3 = Color or COLORS.muted})
end

-- Persistir Config.Enabled cuando el usuario lo toca a mano (no en la
-- restauracion al cargar el script, para no reescribir el archivo antes de
-- que termine de leerlo). Asi "Auto Collect" queda prendido entre sesiones.
local function SetState(On, ShouldSave)
    Config.Enabled = On and true or false
    if ShouldSave ~= false then SaveConfig() end
    if Config.Enabled then
        Cancel = false
        Tween(AutoTrack, 0.2, {BackgroundColor3 = COLORS.good})
        Tween(AutoKnob, 0.2, {Position = UDim2.fromOffset(25, 3)})
        SetStatus("Active", COLORS.good)
        ProcessQueue()
    else
        Cancel = true
        task.delay(0.2, function() Cancel = false end)
        Tween(AutoTrack, 0.2, {BackgroundColor3 = COLORS.off})
        Tween(AutoKnob, 0.2, {Position = UDim2.fromOffset(3, 3)})
        SetStatus("Stopped", COLORS.muted)
        local HRP = GetRoot()
        if HRP then LvStop(HRP) end
    end
end

AutoHit.Activated:Connect(function() SetState(not Config.Enabled) end)

-- Footer credit
local Credit = Instance.new("TextLabel")
Credit.AnchorPoint = Vector2.new(1, 0)
Credit.Position = UDim2.new(1, -16, 0, 408)
Credit.Size = UDim2.fromOffset(60, 14)
Credit.BackgroundTransparency = 1
Credit.Text = "by j"
Credit.TextTransparency = 0.35
Credit.TextXAlignment = Enum.TextXAlignment.Right
Credit.TextColor3 = COLORS.muted
Credit.Font = Enum.Font.GothamMedium
Credit.TextSize = 9
Credit.Parent = Main

task.spawn(function()
    while ScreenGui.Parent do
        CollectedLabel.Text = "🍯 " .. Collected
        task.wait(0.5)
    end
end)

-- ============================================================
-- Auto-scaling, mouse/touch dragging, minimize to a bubble
-- ============================================================
do
    local DRAG_TOLERANCE = 4

    local MainScale = Instance.new("UIScale")
    MainScale.Parent = Main

    local function ClampPosition(Frame, Position)
        local Viewport = ScreenGui.AbsoluteSize
        local Size = Frame.AbsoluteSize
        if Viewport.X <= 0 or Viewport.Y <= 0 or Size.X <= 0 or Size.Y <= 0 then
            return Position
        end
        local Anchor = Frame.AnchorPoint
        local Left = Position.X.Scale * Viewport.X + Position.X.Offset - Anchor.X * Size.X
        local Top  = Position.Y.Scale * Viewport.Y + Position.Y.Offset - Anchor.Y * Size.Y
        Left = math.clamp(Left, 0, math.max(0, Viewport.X - Size.X))
        Top  = math.clamp(Top, 0, math.max(0, Viewport.Y - Size.Y))
        return UDim2.new(
            Position.X.Scale,
            Left + Anchor.X * Size.X - Position.X.Scale * Viewport.X,
            Position.Y.Scale,
            Top + Anchor.Y * Size.Y - Position.Y.Scale * Viewport.Y
        )
    end

    local function ApplyAutoScale()
        local Viewport = ScreenGui.AbsoluteSize
        if Viewport.X <= 0 or Viewport.Y <= 0 then return end
        local Fit = math.min(
            (Viewport.X * 0.9) / BASE_WIDTH,
            (Viewport.Y * 0.9) / BASE_HEIGHT
        )
        MainScale.Scale = math.clamp(Fit, 0.5, 1)
        Main.Position = ClampPosition(Main, Main.Position)
    end

    local function IsDragInput(Input)
        return Input.UserInputType == Enum.UserInputType.MouseButton1
            or Input.UserInputType == Enum.UserInputType.Touch
    end

    local function IsMoveInput(Input)
        return Input.UserInputType == Enum.UserInputType.MouseMovement
            or Input.UserInputType == Enum.UserInputType.Touch
    end

    local function MakeDraggable(Frame, Handle)
        local State = {dragging = false, moved = false}
        local DragStart, StartPosition, ActiveInput

        Handle.InputBegan:Connect(function(Input)
            if not IsDragInput(Input) then return end
            State.dragging = true
            State.moved = false
            DragStart = Input.Position
            StartPosition = Frame.Position
            ActiveInput = Input

            Input.Changed:Connect(function()
                if Input.UserInputState == Enum.UserInputState.End then
                    State.dragging = false
                    ActiveInput = nil
                end
            end)
        end)

        UserInputService.InputChanged:Connect(function(Input)
            if not State.dragging or not IsMoveInput(Input) then return end
            -- El delta tiene que venir del dedo que arranco el drag.
            if Input.UserInputType == Enum.UserInputType.Touch and Input ~= ActiveInput then return end
            local Delta = Input.Position - DragStart
            if math.abs(Delta.X) > DRAG_TOLERANCE or math.abs(Delta.Y) > DRAG_TOLERANCE then
                State.moved = true
            end
            Frame.Position = ClampPosition(Frame, UDim2.new(
                StartPosition.X.Scale,
                StartPosition.X.Offset + Delta.X,
                StartPosition.Y.Scale,
                StartPosition.Y.Offset + Delta.Y
            ))
        end)

        UserInputService.InputEnded:Connect(function(Input)
            if IsDragInput(Input) and Input == ActiveInput then
                State.dragging = false
                ActiveInput = nil
            end
        end)

        return State
    end

    local RestoreButton = Instance.new("TextButton")
    RestoreButton.Name = "RestoreBubble"
    RestoreButton.AnchorPoint = Vector2.new(0.5, 0.5)
    RestoreButton.Position = Main.Position
    RestoreButton.Size = UDim2.fromOffset(52, 52)
    RestoreButton.BackgroundColor3 = COLORS.accent
    RestoreButton.BorderSizePixel = 0
    RestoreButton.AutoButtonColor = false
    RestoreButton.Text = "🍯"
    RestoreButton.TextSize = 22
    RestoreButton.Font = Enum.Font.GothamBold
    RestoreButton.Active = true
    RestoreButton.Visible = false
    RestoreButton.ZIndex = 3
    RestoreButton.Parent = ScreenGui
    Corner(RestoreButton, 99)
    Gradient(RestoreButton, COLORS.accent, COLORS.accent2, 45)
    Stroke(RestoreButton, COLORS.accent2, 0.25, 1.6)

    local function SetMinimized(Minimized)
        if Minimized then
            RestoreButton.Position = ClampPosition(RestoreButton, Main.Position)
            Main.Visible = false
            RestoreButton.Visible = true
        else
            RestoreButton.Visible = false
            Main.Visible = true
            Main.Position = ClampPosition(Main, RestoreButton.Position)
        end
    end

    MakeDraggable(Main, Header)
    local BubbleDrag = MakeDraggable(RestoreButton, RestoreButton)

    MinimizeButton.Activated:Connect(function() SetMinimized(true) end)
    RestoreButton.Activated:Connect(function()
        if BubbleDrag.moved then return end
        SetMinimized(false)
    end)

    -- El slider comparte los eventos globales de input con el drag, asi que se
    -- resuelve aca para que soltar el dedo cierre una sola de las dos cosas.
    UserInputService.InputChanged:Connect(function(Input)
        if SpeedDragging and IsMoveInput(Input) then
            SetSpeedFromX(Input.Position.X, false)
        end
        if SmartSpeedDragging and IsMoveInput(Input) then
            SetSmartSpeedFromX(Input.Position.X, false)
        end
    end)

    UserInputService.InputEnded:Connect(function(Input)
        if SpeedDragging and IsDragInput(Input) then
            SpeedDragging = false
            SetSpeedFromX(Input.Position.X, true)
        end
        if SmartSpeedDragging and IsDragInput(Input) then
            SmartSpeedDragging = false
            SetSmartSpeedFromX(Input.Position.X, true)
        end
    end)

    ScreenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(ApplyAutoScale)
    ApplyAutoScale()
    task.defer(ApplyAutoScale)

    -- El HUD del medio se arma en su propio bloque (abajo) para no sumar
    -- locales aca, pero necesita el mismo drag que el resto: se pasa por la
    -- tabla, que no cuenta contra el limite de 200 del chunk.
    HUD.Drag = MakeDraggable

    -- El panel completo arranca SIEMPRE minimizado: lo que se ve al entrar es
    -- el HUD del medio, y esto queda como burbuja arriba para abrirlo cuando
    -- haga falta. Se la corre del centro para no taparlo.
    SetMinimized(true)
    RestoreButton.Position = ClampPosition(RestoreButton, UDim2.new(0.5, 0, 0, 74))
end

PaintMethods()
PaintHop()
PaintHealth()
PaintShowPath()
PaintSmart()
SyncSpeedDisplay()
SyncSmartSpeedDisplay()
-- Restaura el estado guardado (si Auto Collect quedo prendido la sesion
-- pasada, arranca solo) sin re-guardar lo que se acaba de leer del archivo.
SetState(Config.Enabled, false)

-- ============================================================
-- OPTIMIZER -- menos VFX, mas FPS
-- ------------------------------------------------------------
-- Con varias cuentas abiertas en la misma maquina lo que las frena no es el
-- script sino el mapa: particulas, humo, rayos y sombras. Se apagan (Enabled =
-- false, no Destroy) para poder volver atras sin rejoin.
--
-- Lo que NO se toca, nunca:
--   · Nada colgado de una jarra. El claim depende del ProximityPrompt de la
--     jarra y de que el cliente del juego la siga viendo; romper eso es dejar
--     de recolectar, que es lo contrario de optimizar.
--   · Los personajes, y todo lo que este fuera de workspace -- ahi vive
--     nuestra GUI.
-- Tampoco se apaga el render 3D: los ProximityPrompt dejan de mostrarse y con
-- eso el juego deja de reclamar las jarras.
Boost.KILL = {
    ParticleEmitter = true, Trail = true, Smoke = true,
    Fire = true, Sparkles = true, Beam = true,
}

function Boost.Allowed(Obj)
    local Node = Obj.Parent
    while Node do
        if Node == Workspace then return true end
        if IsHoney(Node) then return false end
        -- La colmena queda afuera: sus VFX son una de las senales con las que
        -- se detecta el evento (ver Bee.FromHiveVfx). Es un solo modelo, no
        -- mueve la aguja de los FPS, y apagarlo era quedarse ciego.
        if Node.Name == "Beehive" then return false end
        if Node:IsA("Model") and Players:GetPlayerFromCharacter(Node) then return false end
        Node = Node.Parent
    end
    return false
end

function Boost.Strip(Obj)
    if not Boost.KILL[Obj.ClassName] then return end
    if not Boost.Allowed(Obj) then return end
    pcall(function() Obj.Enabled = false end)
end

function Boost.Apply()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function()
        local L = game:GetService("Lighting")
        L.GlobalShadows = false
        L.FogEnd = 1e6
        for _, Fx in ipairs(L:GetChildren()) do
            if Fx:IsA("PostEffect") then Fx.Enabled = false end
        end
    end)
    pcall(function()
        local T = Workspace:FindFirstChildOfClass("Terrain")
        if T then
            T.WaterWaveSize = 0
            T.WaterWaveSpeed = 0
            T.WaterReflectance = 0
        end
    end)
    -- El barrido va de a tandas: GetDescendants sobre el mapa entero son
    -- decenas de miles de objetos y hacerlo de un saque cuelga un frame.
    local Done = 0
    for _, Obj in ipairs(Workspace:GetDescendants()) do
        if not Config.Optimizer then return end
        Boost.Strip(Obj)
        Done = Done + 1
        if Done % 800 == 0 then task.wait() end
    end
end

function Boost.Set(On, ShouldSave)
    Config.Optimizer = On and true or false
    if ShouldSave ~= false then SaveConfig() end
    if Config.Optimizer then
        if not Boost.Conn then
            Boost.Conn = Workspace.DescendantAdded:Connect(function(Obj)
                if Config.Optimizer then Boost.Strip(Obj) end
            end)
        end
        task.spawn(Boost.Apply)
    elseif Boost.Conn then
        -- Apagarlo deja de tocar lo nuevo; lo ya apagado se queda asi hasta el
        -- proximo rejoin. Se avisa en el subtitulo del chip.
        Boost.Conn:Disconnect()
        Boost.Conn = nil
    end
end

-- ============================================================
-- HUD -- el cartel del medio
-- ------------------------------------------------------------
-- Lo unico que se ve al entrar: el total de honey de la cuenta, si el evento
-- esta corriendo, y los tres interruptores que importan cuando el bot queda
-- solo. El panel completo (metodo, velocidad, hop) sigue existiendo detras de
-- la burbuja de arriba.
--
-- El total sale del MISMO contador que ve el jugador (LeftBottom > LeftBottom >
-- CurrencyHoney), que es el que ya usaba el reporte al panel -- ahora la
-- lectura vive aca y la usan los dos, asi no hay dos numeros distintos.
function HUD.ResolveLabel()
    if HUD.Label and HUD.Label.Parent then return HUD.Label end
    local OK, Found = pcall(function()
        return PlayerGui.LeftBottom.LeftBottom.CurrencyHoney
    end)
    if OK and typeof(Found) == "Instance" then HUD.Label = Found end
    return HUD.Label
end

-- El label puede venir abreviado ("12.4K", "1.2M") o con separadores
-- ("12,430"). Borrarle todo lo que no sea digito rompe las dos formas: "12.4K"
-- quedaria en 124 y "1.2M" en 12.
HUD.UNITS = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }

function HUD.ParseAmount(Text)
    local Clean = tostring(Text or ""):gsub("[%s,]", "")
    local Num, Unit = Clean:match("(%d+%.?%d*)(%a?)")
    local N = tonumber(Num)
    if not N then return nil end
    return math.floor(N * (HUD.UNITS[Unit:lower()] or 1))
end

-- Devuelve nil si no se pudo leer, NO un contador propio: el panel guarda esto
-- pisando el total anterior, y mandarle un numero de otra magnitud le borraria
-- el honey a la cuenta.
function HUD.ReadHoney()
    local Label = HUD.ResolveLabel()
    if not Label then return nil end
    local OK, Text = pcall(function() return Label.Text end)
    if not OK then return nil end
    return HUD.ParseAmount(Text)
end

function HUD.Comma(N)
    local Out = tostring(math.floor(N or 0))
    local Count
    repeat
        Out, Count = Out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until Count == 0
    return Out
end

do
    local Card = Instance.new("Frame")
    Card.Name = "HoneyHUD"
    Card.AnchorPoint = Vector2.new(0.5, 0.5)
    Card.Position = UDim2.fromScale(0.5, 0.5)
    Card.Size = UDim2.fromOffset(258, 168)
    Card.BackgroundColor3 = Color3.fromRGB(24, 18, 8)
    Card.BackgroundTransparency = 0.28
    Card.BorderSizePixel = 0
    Card.Active = true
    Card.ZIndex = 2
    Card.Parent = ScreenGui
    Corner(Card, 18)
    Stroke(Card, COLORS.accent, 0.45, 1.4)
    HUD.Frame = Card

    local Eyebrow = Instance.new("TextLabel")
    Eyebrow.Position = UDim2.fromOffset(18, 15)
    Eyebrow.Size = UDim2.new(1, -36, 0, 12)
    Eyebrow.BackgroundTransparency = 1
    Eyebrow.Text = "HONEY JARS"
    Eyebrow.TextXAlignment = Enum.TextXAlignment.Left
    Eyebrow.TextColor3 = COLORS.accent
    Eyebrow.TextTransparency = 0.25
    Eyebrow.Font = Enum.Font.GothamBold
    Eyebrow.TextSize = 10
    Eyebrow.ZIndex = 3
    Eyebrow.Parent = Card

    local Value = Instance.new("TextLabel")
    Value.Position = UDim2.fromOffset(18, 29)
    Value.Size = UDim2.new(1, -36, 0, 42)
    Value.BackgroundTransparency = 1
    Value.Text = "-"
    Value.TextXAlignment = Enum.TextXAlignment.Left
    Value.TextColor3 = COLORS.accent2
    Value.Font = Enum.Font.GothamBold
    Value.TextSize = 34
    Value.ZIndex = 3
    Value.Parent = Card
    HUD.Value = Value

    local Dot = Instance.new("Frame")
    Dot.Position = UDim2.fromOffset(19, 82)
    Dot.Size = UDim2.fromOffset(7, 7)
    Dot.BackgroundColor3 = COLORS.off
    Dot.BorderSizePixel = 0
    Dot.ZIndex = 3
    Dot.Parent = Card
    Corner(Dot, 99)
    HUD.Dot = Dot

    local EventText = Instance.new("TextLabel")
    EventText.Position = UDim2.fromOffset(32, 76)
    EventText.Size = UDim2.new(1, -50, 0, 18)
    EventText.BackgroundTransparency = 1
    EventText.Text = "Checking event..."
    EventText.TextXAlignment = Enum.TextXAlignment.Left
    EventText.TextColor3 = COLORS.muted
    EventText.Font = Enum.Font.GothamMedium
    EventText.TextSize = 11
    EventText.ZIndex = 3
    EventText.Parent = Card
    HUD.EventText = EventText

    -- Tres chips: lo que uno quiere poder tocar sin abrir el panel entero.
    HUD.Chips = {}
    local Specs = {
        {key = "WaitEvent", label = "WAIT EVENT"},
        {key = "AntiAfk",   label = "ANTI-AFK"},
        {key = "Optimizer", label = "BOOST FPS"},
    }
    for Index, Spec in ipairs(Specs) do
        local Chip = Instance.new("TextButton")
        Chip.Position = UDim2.fromOffset(18 + (Index - 1) * 76, 104)
        Chip.Size = UDim2.fromOffset(68, 30)
        Chip.BackgroundColor3 = COLORS.button
        Chip.BackgroundTransparency = 0.2
        Chip.BorderSizePixel = 0
        Chip.AutoButtonColor = false
        Chip.Text = Spec.label
        Chip.TextColor3 = COLORS.muted
        Chip.Font = Enum.Font.GothamBold
        Chip.TextSize = 8
        Chip.ZIndex = 3
        Chip.Parent = Card
        Corner(Chip, 9)
        local Edge = Stroke(Chip, COLORS.stroke, 0.4, 1)

        HUD.Chips[Spec.key] = {Button = Chip, Stroke = Edge}
        Chip.Activated:Connect(function()
            if Spec.key == "Optimizer" then
                Boost.Set(not Config.Optimizer)
            else
                Config[Spec.key] = not Config[Spec.key]
                SaveConfig()
            end
            HUD.Sync()
        end)
    end

    local Hint = Instance.new("TextLabel")
    Hint.Position = UDim2.fromOffset(18, 140)
    Hint.Size = UDim2.new(1, -36, 0, 14)
    Hint.BackgroundTransparency = 1
    Hint.Text = "Tap the 🍯 bubble for speed, method and hop"
    Hint.TextXAlignment = Enum.TextXAlignment.Left
    Hint.TextColor3 = COLORS.muted
    Hint.TextTransparency = 0.35
    Hint.Font = Enum.Font.Gotham
    Hint.TextSize = 9
    Hint.ZIndex = 3
    Hint.Parent = Card

    if HUD.Drag then HUD.Drag(Card, Card) end
end

function HUD.Sync()
    local Honey = HUD.ReadHoney()
    HUD.Value.Text = Honey and HUD.Comma(Honey) or "-"

    -- El texto dice el estado completo, el color solo lo repite: el evento
    -- puede estar apagado y el bot igual seguir juntando si WaitEvent no esta.
    local Live = Bee.Active
    HUD.Dot.BackgroundColor3 = Live and COLORS.good or COLORS.bad
    if Live then
        HUD.EventText.Text = "Bee event live"
        HUD.EventText.TextColor3 = COLORS.good
    elseif Config.WaitEvent then
        HUD.EventText.Text = "No event — holding"
        HUD.EventText.TextColor3 = COLORS.bad
    else
        HUD.EventText.Text = "No event — running anyway"
        HUD.EventText.TextColor3 = COLORS.muted
    end

    for Key, Chip in pairs(HUD.Chips) do
        local On = Config[Key] and true or false
        Chip.Button.TextColor3 = On and COLORS.accent or COLORS.muted
        Chip.Stroke.Color = On and COLORS.accent or COLORS.stroke
        Chip.Stroke.Transparency = On and 0.3 or 0.5
        Chip.Button.BackgroundTransparency = On and 0.05 or 0.35
    end
end

-- ============================================================
-- ANTI-AFK
-- ------------------------------------------------------------
-- Roblox avisa con Idled antes de tirar por inactividad. Un click con
-- VirtualUser alcanza para resetear el contador y no toca nada del juego.
do
    local Virtual
    pcall(function() Virtual = game:GetService("VirtualUser") end)
    if Virtual then
        LocalPlayer.Idled:Connect(function()
            if not Config.AntiAfk or MyToken ~= G.__HoneyTPRun then return end
            pcall(function()
                Virtual:CaptureController()
                Virtual:ClickButton2(Vector2.new())
            end)
        end)
    else
        warn("[HONEY TP] anti-afk: your executor does not expose VirtualUser")
    end
end

-- Un solo loop mantiene al dia el tracker y el HUD.
task.spawn(function()
    while MyToken == G.__HoneyTPRun do
        pcall(Bee.Refresh)
        pcall(HUD.Sync)
        task.wait(1)
    end
end)

if Config.Optimizer then Boost.Set(true, false) end
HUD.Sync()

print(("[HONEY TP] method: %s | speed: %d | autohop: %s | smart: %s"):format(
    Config.Method, Config.Speed, tostring(Config.AutoHop), tostring(Config.SmartTP)))

-- ============================================================
-- HONEY HUB REPORTING -- opcional, activado solo si llegaron URL y token
-- ------------------------------------------------------------
-- Todo el bloque vive en el scope del collector: no hace falta ningun puente
-- (getgenv().HoneyHubBridge) ni pegar nada a mano al final del script. Lee y
-- escribe Config, SetStatus, SetState, etc. directo, porque literalmente
-- corre dentro del mismo archivo.
--
-- El identificador de instancia es el mismo MyToken del collector (contra
-- G.__HoneyTPRun): no hace falta un contador aparte para el reporte, porque
-- ya es una unica corrida. El token de Railway (HubToken) es otra cosa --
-- autentica contra el panel, identifica al usuario dueno de la cuenta -- y
-- se mantiene separado a proposito.
-- ============================================================
if HubBaseUrl ~= "" and HubToken ~= "" then
    -- Cada ejecutor expone el request con otro nombre. Se resuelve una vez.
    local HubHttpJson, HubHttpPost
    do
        local impl = (syn and syn.request)
            or (http and http.request)
            or http_request
            or request
            or (fluxus and fluxus.request)

        if type(impl) == "function" then
            function HubHttpJson(Method, Path, Body)
                local Options = {
                    Url = HubBaseUrl .. Path,
                    Method = Method,
                    Headers = {
                        ["Content-Type"]  = "application/json",
                        ["Authorization"] = "Bearer " .. HubToken,
                    },
                }
                -- Un GET con Body vacio hace renegar a varios ejecutores, asi
                -- que el campo directamente no va cuando no hay cuerpo.
                if Body ~= nil then
                    Options.Body = HttpService:JSONEncode(Body)
                end

                local ok, res = pcall(impl, Options)
                if not ok or type(res) ~= "table" then return nil end
                if (res.StatusCode or res.status_code or 0) >= 400 then return nil end

                local decoded
                pcall(function()
                    decoded = HttpService:JSONDecode(res.Body or res.body or "{}")
                end)
                return decoded
            end

            function HubHttpPost(Path, Body)
                return HubHttpJson("POST", Path, Body)
            end
        end
    end

    if not HubHttpPost then
        warn("[HONEY TP] Hub: your executor does not expose request/http_request -- cannot report")
    else
        -- Envuelve SetStatus (ya existe, la GUI lo llama todo el tiempo) para
        -- que el panel muestre el MISMO texto que ve el usuario en el juego.
        local HubStatusText, HubStatusKind = "Idle", "idle"
        local function HubClassifyStatus(Text)
            local Lower = tostring(Text):lower()
            if Lower:find("collecting") then return "collecting" end
            -- Antes que "hop" y que "waiting": el texto del freno por evento
            -- contiene las dos palabras y se leeria como otra cosa.
            if Lower:find("bee event") then return "waiting_event" end
            if Lower:find("hop") or Lower:find("small server") then return "hopping" end
            if Lower:find("waiting") then return "waiting" end
            if Lower:find("stopped") then return "stopped" end
            return Config.Enabled and "waiting" or "idle"
        end

        local HubRawSetStatus = SetStatus
        SetStatus = function(Text, Color)
            HubStatusText = Text
            HubStatusKind = HubClassifyStatus(Text)
            return HubRawSetStatus(Text, Color)
        end

        local HubClientId = HttpService:GenerateGUID(false)

        -- Enganche del FETCHER (los slots declarados arriba de todo). A partir
        -- de aca el hop pide jobIds al panel en vez de paginar Roblox por su
        -- cuenta. Si el panel no tiene el fetcher prendido, /api/fetch/server
        -- contesta 503, HubHttpJson devuelve nil, y Hop.Pick cae solo al
        -- camino de siempre -- no hay nada que configurar en el script.
        Hop.Take = function(Count)
            local Res = HubHttpJson(
                "GET",
                ("/api/fetch/server?size=%d&max=%d"):format(Count, HOP_MAX_PLAYERS)
            )
            if type(Res) == "table" and type(Res.jobIds) == "table" then
                return Res.jobIds
            end
            return nil
        end

        Hop.Drop = function(JobId)
            -- La respuesta trae un reemplazo listo; se encola para que el
            -- proximo intento no tenga que pedir de nuevo.
            local Res = HubHttpJson("POST", "/api/fetch/drop", { jobId = JobId })
            if type(Res) == "table" then Hop.Push(Res.jobIds) end
        end

        local function HubSnapshot()
            return {
                token   = HubToken,
                client  = HubClientId,
                roblox  = {
                    id      = LocalPlayer.UserId,
                    name    = LocalPlayer.Name,
                    display = LocalPlayer.DisplayName,
                },
                honey      = HUD.ReadHoney(),
                status     = HubStatusText,
                statusKind = HubStatusKind,
                method     = Config.Method,
                speed      = Config.Speed,
                autoHop    = Config.AutoHop,
                smartTP    = Config.SmartTP,
                sweepRoute = Config.SweepRoute,
                enabled    = Config.Enabled,
                -- El tracker del evento viaja con cada beat: es lo que le
                -- permite al panel decir si una cuenta esta parada porque no
                -- hay evento o porque algo se rompio.
                event      = Bee.Active,
                waitEvent  = Config.WaitEvent,
                antiAfk    = Config.AntiAfk,
                optimizer  = Config.Optimizer,
                jobId      = game.JobId,
                placeId    = game.PlaceId,
                players    = #Players:GetPlayers(),
            }
        end

        -- Los comandos que manda el panel se aplican directo sobre el
        -- collector: es el mismo scope, no hace falta indireccion via bridge.
        -- Ninguno de estos dispara un remote del juego -- solo tocan Config
        -- (que ya maneja la GUI local) y, para "hop", TeleportService, que es
        -- la API estandar de Roblox para cambiar de server, no un remote del
        -- juego que un anti-cheat pueda marcar como ajeno.
        local function HubApplyCommand(Kind, Value)
            if Kind == "enabled" then
                SetState(Value == "on")

            elseif Kind == "method" then
                Config.Method = Value
                SaveConfig()
                PaintMethods()
                -- Mismo gesto que el boton de la GUI: cortar el viaje en curso
                -- para que el metodo nuevo se use ya, no recien en el proximo jar.
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

            elseif Kind == "sweep" then
                Config.SweepRoute = (Value == "on")
                SaveConfig()
                Route.Paint()

            elseif Kind == "waitevent" then
                Config.WaitEvent = (Value == "on")
                SaveConfig()
                HUD.Sync()

            elseif Kind == "antiafk" then
                Config.AntiAfk = (Value == "on")
                SaveConfig()
                HUD.Sync()

            elseif Kind == "optimizer" then
                Boost.Set(Value == "on")
                HUD.Sync()

            elseif Kind == "hop" then
                -- HopToSmallServer loopea mientras AutoHop este prendido; para un
                -- salto puntual se llama directo al buscador y se teleporta una vez.
                -- Nunca un Teleport a ciegas (sin Server.id) -- eso deja elegir al
                -- matchmaker de Roblox, que puede devolverte al mismo server del
                -- que saliste. Si la busqueda no encuentra nada, reintenta un par
                -- de veces antes de rendirse.
                task.spawn(function()
                    SetStatus("Manual hop from the panel...", COLORS.bad)
                    for _ = 1, 4 do
                        local JobId, Origen = Hop.Pick()
                        if JobId then
                            Hop.Teleport(JobId, Origen)
                            break
                        end
                        task.wait(1.5)
                    end
                end)
            end
        end

        local HubAcked = {}
        local function HubHandleCommands(List)
            if type(List) ~= "table" then return end
            for _, Command in ipairs(List) do
                if type(Command) == "table" and Command.id then
                    local ok, err = pcall(HubApplyCommand, Command.kind, Command.value)
                    if not ok then
                        warn("[HONEY TP] Hub: command '" .. tostring(Command.kind) .. "' failed -- " .. tostring(err))
                    end
                    table.insert(HubAcked, Command.id)
                end
            end
        end

        local HubBeatMs = 2000

        task.spawn(function()
            local Hello = HubHttpPost("/api/bot/hello", HubSnapshot())
            if not Hello then
                warn("[HONEY TP] Hub: could not register -- check the URL and the token")
                return
            end
            if type(Hello.beatMs) == "number" then HubBeatMs = Hello.beatMs end
            HubHandleCommands(Hello.commands)

            print(("[HONEY TP] Hub: connected as %s (beat %dms)"):format(LocalPlayer.Name, HubBeatMs))

            while MyToken == G.__HoneyTPRun do
                local Payload = HubSnapshot()
                if #HubAcked > 0 then
                    Payload.ack = HubAcked
                    HubAcked = {}
                end

                local Res = HubHttpPost("/api/bot/beat", Payload)
                if Res then
                    if type(Res.beatMs) == "number" then HubBeatMs = Res.beatMs end
                    HubHandleCommands(Res.commands)
                end

                task.wait(HubBeatMs / 1000)
            end
        end)

        -- Aviso de cierre: sin esto la cuenta queda "online" en el panel hasta
        -- que vence la ventana de inactividad.
        --
        -- game:BindToClose SOLO corre en scripts de servidor -- desde un
        -- script inyectado (que para este chequeo cuenta como LocalScript)
        -- SIEMPRE tira "BindToClose can only be called on the server.". Sin
        -- pcall eso no era un aviso: cortaba la ejecucion del chunk principal
        -- ahi mismo, y la conexion de OnTeleport de abajo -- que es la que de
        -- verdad importa en un juego con auto-hop -- nunca llegaba a
        -- registrarse. honey_hub.lua lo reportaba como "the collector failed
        -- to start", pero para entonces los task.spawn de arriba (el loop de
        -- beat incluido) ya habian arrancado y seguian corriendo solos: era
        -- una falsa alarma que de paso tapaba un bug real.
        pcall(function()
            game:BindToClose(function()
                pcall(HubHttpPost, "/api/bot/bye", { token = HubToken, client = HubClientId })
            end)
        end)

        LocalPlayer.OnTeleport:Connect(function(State)
            if State == Enum.TeleportState.Started then
                pcall(HubHttpPost, "/api/bot/bye", { token = HubToken, client = HubClientId })
            end
        end)
    end
end
