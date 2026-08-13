--[[
    ╔══════════════════════════════════════════════════════════════╗
    ║   HONEY MERCHANT — Compra selectiva del BeeMerchantService    ║
    ╚══════════════════════════════════════════════════════════════╝

    Un solo archivo autocontenido: lógica + GUI nativa.

    GUI
      100% Instances de Roblox. Sin loadstring a librerías externas
      (esa URL era un punto único de falla: si no cargaba, moría todo
      el script antes de dibujar nada). Cuatro pestañas:

        Tienda  → catálogo, cantidad, método y compra manual
        Sniper  → lista de objetivos + auto-compra al haber stock
        Log     → historial de cada compra (qué, cuánto, cuándo, cómo salió)
        Stats   → gastado, comprados, tasa de éxito, tiempo medio de snipe

    SNIPER MULTI-OBJETIVO
      Ya no vigila un solo producto: marcás con 🎯 los que quieras y
      el sniper los recorre en cada frame, comprando el que tenga
      stock con la cantidad configurada por objetivo. Necesita la
      tienda abierta — con la tienda cerrada no se puede leer el
      estado real ni apretar el botón, así que queda en espera en vez
      de disparar a ciegas. Re-dispara en cada restock.

    DOS MÉTODOS DE COMPRA (seleccionables en la GUI)
      1. UI del juego  — busca el botón real de la tienda en PlayerGui
                         y le hace firesignal, igual que InstantClone
                         en hub.lua:1046-1061. El cliente del juego
                         dispara sus propios remotos con todo el estado
                         que el servidor espera (foco en el NPC, etc).
      2. Remoto directo — InvokeServer sobre BeeMerchantService/Buy.
                         Más simple, pero el servidor puede rechazarlo
                         si exige interacción previa con el comerciante.

    SIN NAMECALL HOOK
      La info de productos sale de require() directo sobre los módulos
      del juego; la compra usa InvokeServer / firesignal normales.

    ENV LEAK
      Todo lo que cruza hacia código del juego pasa por Env (abajo):
      entorno prestado de un LocalScript real, identidad de hilo de
      LocalScript, y la llamada naciendo en un hilo propio para no
      dejar frames nuestros en la pila.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ═══════════════════════════ ENV LEAK ═══════════════════════════
--
-- Cada vez que llamamos a código del juego (require de sus módulos, los
-- métodos de Net, InvokeServer, los handlers que despierta firesignal)
-- ese código corre en un contexto que no se parece en nada al de un
-- LocalScript normal, y desde adentro se nota:
--
--   · el entorno global tiene lo que inyecta el ejecutor (getgenv,
--     hookfunction, readfile...) y le falta `script`, así que un
--     getfenv(nivel) desde el módulo canta al toque;
--   · la identidad del hilo es la elevada del ejecutor (7/8) en vez de
--     la 2 que tiene un LocalScript;
--   · arriba de la llamada quedan los frames de este archivo, con su
--     chunk name de loadstring.
--
-- Env arma un espejo contra las tres cosas: presta el entorno de un
-- LocalScript real del juego, baja la identidad mientras dura la
-- llamada, y hace nacer la llamada en un hilo aparte para que arriba
-- del trampolín no haya un solo frame nuestro.
--
-- Todo es best-effort: si el ejecutor no trae getrenv/getsenv/setfenv/
-- setthreadidentity, cada capa se cae sola y el resto sigue andando.
-- Env.Report cuenta qué quedó parchado (se ve en la pestaña Stats).

local Env = {}
do
    local GAME_IDENTITY = 2   -- la de un LocalScript
    local CALL_TIMEOUT = 10

    -- ── 1. las globales reales, sin lo que inyecta el ejecutor ──
    local RealEnv
    pcall(function()
        if type(getrenv) == "function" then RealEnv = getrenv() end
    end)
    if type(RealEnv) ~= "table" then RealEnv = nil end

    -- El `require` del ejecutor suele venir envuelto; queremos el del juego.
    local RealRequire = (RealEnv and rawget(RealEnv, "require")) or require

    -- ── 2. LocalScripts del juego cuyo entorno podamos prestar ──
    -- getsenv sólo funciona con scripts que estén corriendo, y de afuera
    -- no hay forma de saber cuáles lo están: juntamos varios candidatos y
    -- después probamos uno por uno. getrunningscripts va primero cuando
    -- existe porque ya filtra por eso; si no, PlayerScripts, que siempre
    -- tiene LocalScripts vivos del juego.
    local MAX_CANDIDATES = 12

    local function CollectHostScripts()
        local Found, Seen = {}, {}

        local function Absorb(Pool)
            for _, Object in ipairs(Pool) do
                if #Found >= MAX_CANDIDATES then return end
                local OK, IsLocal = pcall(function() return Object:IsA("LocalScript") end)
                if OK and IsLocal and not Seen[Object] then
                    Seen[Object] = true
                    table.insert(Found, Object)
                end
            end
        end

        pcall(function()
            if type(getrunningscripts) == "function" then Absorb(getrunningscripts()) end
        end)
        pcall(function()
            local PlayerScripts = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
            if PlayerScripts then Absorb(PlayerScripts:GetDescendants()) end
        end)
        pcall(function() Absorb(PlayerGui:GetDescendants()) end)

        return Found
    end

    local Candidates = CollectHostScripts()

    -- ── 3. el entorno espejo ──
    local HostScript = Candidates[1]
    local Mirror, MirrorKind = nil, "ninguno"

    -- Lo mejor: el entorno literal de un script del juego. Indistinguible
    -- porque no es una imitación, es uno de verdad.
    if type(getsenv) == "function" then
        for _, Script_ in ipairs(Candidates) do
            local OK, Candidate = pcall(getsenv, Script_)
            if OK and type(Candidate) == "table" then
                HostScript, Mirror, MirrorKind = Script_, Candidate, "prestado"
                break
            end
        end
    end

    -- Respaldo: un entorno de LocalScript es exactamente esto — una tabla
    -- con `script` adentro y __index apuntando a las globales reales.
    if not Mirror and RealEnv then
        if HostScript then
            Mirror = setmetatable({ script = HostScript }, { __index = RealEnv })
            MirrorKind = "imitado"
        else
            Mirror, MirrorKind = RealEnv, "globales"
        end
    end

    -- El trampolín: el único frame Lua entre nosotros y el juego. Su
    -- entorno es el espejo, así que cualquier getfenv que suba desde el
    -- módulo aterriza acá y ve un LocalScript.
    local Invoke = function(Fn, ...) return Fn(...) end

    -- El cuerpo del hilo de Env.Call también es un frame Lua sobre el
    -- juego, así que va con el mismo entorno. Se define una sola vez y
    -- recibe el buzón por argumento en vez de capturarlo: si capturara,
    -- haría falta un closure nuevo (y otro setfenv) por llamada.
    -- table.pack y pcall van como upvalues — setfenv no los toca, así que
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

    -- ── 4. identidad de hilo ──
    local GetIdentity, SetIdentity
    do
        local function Pick(Getter, Setter)
            if type(Getter) == "function" and type(Setter) == "function" then
                GetIdentity, SetIdentity = Getter, Setter
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

    local IdentityOK = (GetIdentity ~= nil and SetIdentity ~= nil)

    -- Corre Fn como si fuera un LocalScript del juego.
    -- Devuelve igual que pcall: OK, resultados...
    --
    -- El hilo aparte no es capricho: llamando derecho, arriba del
    -- trampolín quedarían los frames de este archivo y un getfenv(4) los
    -- encuentra. Naciendo en un hilo nuevo, arriba de Invoke no hay nada.
    -- Y como el módulo puede ceder (WaitForChild, InvokeServer) esperamos
    -- a que el hilo muera en vez de confiar en lo que devuelve el resume.
    -- Si no cede, resume corre entero de una y no se pierde ni un frame.
    function Env.Call(Fn, ...)
        -- Sólo bajamos la identidad si primero pudimos leer la vieja: si
        -- no, no habría con qué volver y este hilo se quedaría en 2 para
        -- siempre, sin privilegios de ejecutor.
        local Previous
        if IdentityOK then
            local ReadOK = pcall(function() Previous = GetIdentity() end)
            if ReadOK and Previous ~= nil then
                pcall(SetIdentity, GAME_IDENTITY)
            else
                Previous = nil
            end
        end

        -- El hilo se crea con la identidad ya bajada: la hereda.
        local Slot = { Finished = false }
        local Thread = coroutine.create(Runner)
        coroutine.resume(Thread, Slot, Fn, ...)

        local Deadline = os.clock() + CALL_TIMEOUT
        while not Slot.Finished and os.clock() < Deadline do
            RunService.Heartbeat:Wait()
        end

        if Previous ~= nil then pcall(SetIdentity, Previous) end

        if not Slot.Finished then
            return false, "La llamada al juego no respondió"
        end
        return table.unpack(Slot.Output, 1, Slot.Output.n)
    end

    -- Mismo espejo de entorno, pero sin bajar la identidad ni saltar de
    -- hilo: firesignal necesita los privilegios del ejecutor, y el sniper
    -- no puede permitirse el salto de frame.
    function Env.CallElevated(Fn, ...)
        return pcall(Invoke, Fn, ...)
    end

    -- Cachear el resultado no es sólo velocidad: cada require repetido es
    -- otro cruce hacia el juego, y el primero es el único que ejecuta el
    -- chunk del módulo (el resto ya los sirve la caché de Roblox).
    local ModuleCache = {}
    function Env.Require(Module)
        local Cached = ModuleCache[Module]
        if Cached ~= nil then return true, Cached end
        local OK, Result = Env.Call(RealRequire, Module)
        if OK then ModuleCache[Module] = Result end
        return OK, Result
    end

    Env.Report = {
        Mirror = MirrorKind,
        Host = HostScript and HostScript.Name or nil,
        Fenv = FenvOK,
        Identity = IdentityOK,
    }
end

-- Re-ejecutar el script no debe dejar dos ventanas peleando por el
-- mismo sniper: matamos la anterior antes de dibujar la nueva.
local Global = (type(getgenv) == "function") and getgenv() or nil
if Global and Global.HoneyMerchantGui then
    pcall(function() Global.HoneyMerchantGui:Destroy() end)
end

-- ═══════════════════════════ NET (perezoso, igual que hub.lua) ═══════════════════════════

-- Baja por el árbol sin explotar si falta un eslabón. Recorrer Instances
-- no mete frames Lua en el juego, así que esto no necesita a Env.
local function FindModule(...)
    local Node = ReplicatedStorage
    for _, Part in ipairs({...}) do
        if not Node then return nil end
        local OK, Child = pcall(Node.WaitForChild, Node, Part, 5)
        Node = OK and Child or nil
    end
    return Node
end

local NetModule
local function LoadNet()
    if NetModule then return true end
    local NetFolder = FindModule("Packages", "Net")
    if not NetFolder then return false end
    local NetScript = NetFolder:FindFirstChildWhichIsA("ModuleScript", true)
    if not NetScript then return false end
    local OK, Mod = Env.Require(NetScript)
    if not OK or type(Mod) ~= "table" then return false end
    NetModule = Mod
    return true
end

local BuyRemote
local function GetBuyRemote()
    if BuyRemote then return BuyRemote end
    if not LoadNet() then return nil end
    -- Nada de closures nuestras en el medio: si envolviéramos esto en una
    -- función definida acá, el getfenv(2) de Net caería en el entorno de
    -- ESTE archivo. Pasamos el método suelto con el módulo de argumento,
    -- así el único frame Lua sobre Net es el trampolín de Env.
    local OK, Remote = Env.Call(NetModule.RemoteFunction, NetModule, "BeeMerchantService/Buy")
    if not OK or Remote == nil then return nil end
    BuyRemote = Remote
    return BuyRemote
end

-- ═══════════════════════════ DATOS ═══════════════════════════

local function GetProducts()
    local DataModule = FindModule("Datas", "BeeMerchantData")
    if not DataModule then
        return nil, "No se encontró ReplicatedStorage.Datas.BeeMerchantData"
    end

    local DataOK, Data = Env.Require(DataModule)
    if not DataOK or type(Data) ~= "table" or type(Data.Brainrots) ~= "table" then
        return nil, "No se pudo leer BeeMerchantData"
    end

    -- Los precios vivos son opcionales: sin ellos caemos al Price del catálogo.
    local LivePrices
    local FlagsModule = FindModule("Shared", "Flags", "BeeMerchantFlags")
    if FlagsModule then
        local FlagsOK, Flags = Env.Require(FlagsModule)
        if FlagsOK and type(Flags) == "table" and type(Flags.HoneyPrices) == "table" then
            LivePrices = Flags.HoneyPrices
        end
    end

    local Products = {}
    for _, Entry in ipairs(Data.Brainrots) do
        local Name = Entry.Brainrot
        table.insert(Products, {
            Name = Name,
            Price = (LivePrices and LivePrices[Name]) or Entry.Price,
            Stock = Entry.Stock,
            RobuxPrice = Entry.RobuxPrice,
            ProductId = Entry.ProductId,
        })
    end

    return Products
end

-- ═══════════════════════════ COMPRA ═══════════════════════════

-- Método 1: apretar el botón real de la tienda del juego.
-- Ruta confirmada con tools/dump-merchant-ui.lua (tienda abierta):
--   PlayerGui.BeeMerchant.BeeMerchant.<1..5>.BuyYellow
-- Cada entrada numerada tiene ".Buy" (compra con Robux) y ".BuyYellow"
-- (compra con Honey — el texto del botón coincide exacto con el Price
-- de BeeMerchantData: 20, 40, 100, 200, 400). Mismo patrón que
-- Movement:InstantClone (hub.lua:1046-1061): buscar el botón real y
-- firesignal, sin tocar remotos directamente.
-- ImageButton no tiene .Text (sólo TextButton/TextLabel lo tienen) — el
-- precio que se ve en el botón vive en un TextLabel adentro. Buscamos
-- igual que TextInside() en tools/dump-merchant-ui.lua.
local function FindLabelText(Instance_)
    if (Instance_:IsA("TextLabel") or Instance_:IsA("TextButton")) and Instance_.Text ~= "" then
        return Instance_.Text
    end
    for _, Descendant in ipairs(Instance_:GetDescendants()) do
        if (Descendant:IsA("TextLabel") or Descendant:IsA("TextButton")) and Descendant.Text ~= "" then
            return Descendant.Text
        end
    end
    return nil
end

-- Palabras que el juego usa para marcar sin stock en la tienda hermana
-- (Merchant/BrainrotTrader, mismo patrón de UI: "SOLD OUT", "NO STOCK").
local OUT_OF_STOCK_MARKERS = { "sold out", "no stock", "out of stock", "agotado", "sin stock" }

local function IsTexty(Object)
    return Object:IsA("TextLabel") or Object:IsA("TextButton")
end

-- El sniper consulta el stock en cada frame, y resolver el botón implica
-- recorrer el árbol de la tienda — cada entrada tiene un ViewportFrame
-- con el modelo 3D entero adentro (cientos de descendientes). Así que
-- resolvemos una vez por producto y cacheamos el botón + la lista de
-- etiquetas de texto a leer. Por frame sólo se recorre esa lista corta.
local Resolved = {}

local function DropResolved(Name)
    local Cached = Resolved[Name]
    if Cached and Cached.Connection then
        Cached.Connection:Disconnect()
    end
    Resolved[Name] = nil
end

local function CollectLabels(Entry)
    local Labels = {}
    for _, Descendant in ipairs(Entry:GetDescendants()) do
        if IsTexty(Descendant) then
            table.insert(Labels, Descendant)
        end
    end
    return Labels
end

-- Devuelve la entrada cacheada {Button, Entry, Labels} o nil + error.
local function ResolveProduct(Product)
    -- Cerrar la tienda sólo apaga el ScreenGui (Enabled = false): las
    -- instancias siguen ahí con padre, así que hay que chequear esto
    -- SIEMPRE, también con caché válida — si no, el sniper dispararía
    -- clicks al vacío creyendo que la tienda está abierta.
    local MerchantGui = PlayerGui:FindFirstChild("BeeMerchant")
    if not MerchantGui or not MerchantGui.Enabled then
        return nil, "La tienda no está abierta"
    end

    local Cached = Resolved[Product.Name]
    if Cached and Cached.Button.Parent and Cached.Entry.Parent then
        return Cached
    end
    DropResolved(Product.Name)

    local MerchantFrame = MerchantGui:FindFirstChild("BeeMerchant")
    if not MerchantFrame then
        return nil, "La tienda no está abierta (PlayerGui.BeeMerchant.BeeMerchant no existe)"
    end

    local Lowered = Product.Name:lower()
    local Found, FoundEntry

    -- 1. match por el nombre visible en la entrada (Background.Name)
    for _, Entry in ipairs(MerchantFrame:GetChildren()) do
        if tonumber(Entry.Name) then -- entradas numeradas: 1, 2, 3, 4, 5
            local BuyYellow = Entry:FindFirstChild("BuyYellow", true)
            local NameLabel = Entry:FindFirstChild("Name", true)
            if BuyYellow and BuyYellow:IsA("GuiButton") and NameLabel and IsTexty(NameLabel) then
                if NameLabel.Text ~= "" and NameLabel.Text:lower():find(Lowered, 1, true) then
                    Found, FoundEntry = BuyYellow, Entry
                    break
                end
            end
        end
    end

    -- 2. respaldo: el precio en BuyYellow es único por producto
    if not Found then
        for _, Entry in ipairs(MerchantFrame:GetChildren()) do
            if tonumber(Entry.Name) then
                local BuyYellow = Entry:FindFirstChild("BuyYellow", true)
                if BuyYellow and BuyYellow:IsA("GuiButton") then
                    local PriceText = FindLabelText(BuyYellow)
                    local ButtonPrice = PriceText and tonumber((PriceText:gsub("%D", "")))
                    if ButtonPrice == Product.Price then
                        Found, FoundEntry = BuyYellow, Entry
                        break
                    end
                end
            end
        end
    end

    if not Found then
        return nil, "No se encontró el botón de " .. Product.Name .. " en la tienda abierta"
    end

    local Name = Product.Name
    local NewCache = {
        Button = Found,
        Entry = FoundEntry,
        Labels = CollectLabels(FoundEntry),
    }
    -- si el juego crea la etiqueta de "SOLD OUT" en caliente, la sumamos
    NewCache.Connection = FoundEntry.DescendantAdded:Connect(function(Descendant)
        if IsTexty(Descendant) then
            table.insert(NewCache.Labels, Descendant)
        end
    end)

    Resolved[Name] = NewCache
    return NewCache
end

local function CacheLooksOutOfStock(Cached)
    for _, Label in ipairs(Cached.Labels) do
        if Label.Parent and Label.Text ~= "" then
            local Lowered = Label.Text:lower()
            for _, Marker in ipairs(OUT_OF_STOCK_MARKERS) do
                if Lowered:find(Marker, 1, true) then
                    return true
                end
            end
        end
    end
    -- señal secundaria: el juego suele desactivar el input del botón
    if Cached.Button.Active == false then
        return true
    end
    return false
end

-- Chequeo de stock en vivo, sin gastar un click. Devuelve true/false/nil
-- (nil = no se pudo determinar, ej. tienda cerrada).
local function CheckStock(Product)
    local Cached = ResolveProduct(Product)
    if not Cached then return nil end
    return not CacheLooksOutOfStock(Cached)
end

local function BuyViaGameUI(Product)
    local Cached, FindError = ResolveProduct(Product)
    if not Cached then
        return false, FindError or ("No se encontró el botón de " .. Product.Name)
    end

    if CacheLooksOutOfStock(Cached) then
        return false, "Sin stock ahora mismo"
    end

    -- Los handlers del juego se despiertan desde adentro de firesignal, o
    -- sea que el frame Lua que van a ver arriba es el trampolín de Env.
    -- Acá va CallElevated y no Call: firesignal necesita la identidad del
    -- ejecutor, y bajarla lo rompe.
    local Button = Cached.Button
    local Fired = false
    if typeof(firesignal) == "function" then
        Fired = Env.CallElevated(firesignal, Button.MouseButton1Click)
        Env.CallElevated(firesignal, Button.MouseButton1Up)
        Env.CallElevated(firesignal, Button.Activated)
    else
        local Signal = Button.MouseButton1Click
        Fired = Env.CallElevated(Signal.Fire, Signal)
    end

    if not Fired then
        return false, "El ejecutor no soporta firesignal"
    end
    -- El juego no nos devuelve un resultado por esta vía: sólo confirmamos el disparo.
    return true, "Botón de tienda disparado"
end

-- Método 2: remoto directo.
local function BuyViaRemote(ProductName)
    local Remote = GetBuyRemote()
    if not Remote then
        return false, "No se encontró el remoto (BeeMerchantService/Buy)"
    end

    -- Mismo criterio que en GetBuyRemote: el método suelto, sin closure
    -- nuestra que el servidor pueda mirar desde el otro lado del remoto.
    local OK, Result = Env.Call(Remote.InvokeServer, Remote, ProductName)

    if not OK then
        return false, "Error de conexión: " .. tostring(Result)
    end
    if Result then
        return true, "Compra confirmada por el servidor"
    end
    return false, "Compra rechazada por el servidor"
end

-- Default: UI del juego. La ruta ya está confirmada (dump con la tienda
-- abierta), así que puede ser el método principal, igual que InstantClone.
local UseGameUI = true

local function Buy(Product)
    if type(Product) ~= "table" or type(Product.Name) ~= "string" then
        return false, "Producto inválido"
    end
    if UseGameUI then
        return BuyViaGameUI(Product)
    end
    return BuyViaRemote(Product.Name)
end

-- ═══════════════════════════ ESTADÍSTICAS ═══════════════════════════

-- Sobreviven a re-ejecutar el script: viven en getgenv() si existe.
local Stats = (Global and Global.HoneyMerchantStats) or {
    Items = 0,        -- unidades compradas OK
    Spent = 0,        -- honey gastado (Price × unidades)
    Attempts = 0,     -- intentos individuales (una unidad = un intento)
    Fails = 0,        -- intentos que devolvieron false
    Snipes = 0,       -- unidades compradas por el sniper
    SnipeWaits = 0,   -- suma de segundos esperando cada snipe
    SnipeCount = 0,   -- cuántos disparos de sniper se midieron
    StartedAt = os.clock(),
}
if Global then Global.HoneyMerchantStats = Stats end

local History = (Global and Global.HoneyMerchantHistory) or {}
if Global then Global.HoneyMerchantHistory = History end

local HISTORY_MAX = 80

local function Comma(Number)
    local Text = tostring(math.floor(Number))
    while true do
        local Replacements
        Text, Replacements = Text:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
        if Replacements == 0 then break end
    end
    return Text
end

local function ShortTime(Seconds)
    if Seconds < 60 then return string.format("%.0fs", Seconds) end
    if Seconds < 3600 then return string.format("%dm %ds", Seconds // 60, Seconds % 60) end
    return string.format("%dh %dm", Seconds // 3600, (Seconds % 3600) // 60)
end

-- ═══════════════════════════ TEMA ═══════════════════════════

local Theme = {
    Base        = Color3.fromRGB(16, 15, 20),
    Surface     = Color3.fromRGB(25, 24, 31),
    SurfaceAlt  = Color3.fromRGB(33, 31, 40),
    Card        = Color3.fromRGB(38, 36, 46),
    CardHover   = Color3.fromRGB(49, 46, 59),
    Honey       = Color3.fromRGB(255, 190, 60),
    HoneyDeep   = Color3.fromRGB(238, 150, 30),
    Text        = Color3.fromRGB(242, 240, 247),
    TextDim     = Color3.fromRGB(150, 146, 162),
    TextFaint   = Color3.fromRGB(104, 100, 118),
    TextOnHoney = Color3.fromRGB(38, 26, 4),
    Stroke      = Color3.fromRGB(56, 53, 68),
    Success     = Color3.fromRGB(115, 225, 145),
    Warning     = Color3.fromRGB(255, 195, 90),
    Error       = Color3.fromRGB(255, 105, 105),
    Info        = Color3.fromRGB(120, 180, 255),
}

local TierColors = {
    Color3.fromRGB(125, 225, 155),
    Color3.fromRGB(255, 210, 95),
    Color3.fromRGB(255, 165, 65),
    Color3.fromRGB(255, 115, 95),
    Color3.fromRGB(195, 135, 255),
}

local Quick = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local Smooth = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function Tween(Object, Info, Props)
    TweenService:Create(Object, Info, Props):Play()
end

local function Corner(Parent, Radius)
    local C = Instance.new("UICorner")
    C.CornerRadius = UDim.new(0, Radius)
    C.Parent = Parent
    return C
end

local function Stroke(Parent, Color, Thickness, Transparency)
    local S = Instance.new("UIStroke")
    S.Color = Color or Theme.Stroke
    S.Thickness = Thickness or 1
    S.Transparency = Transparency or 0
    S.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    S.Parent = Parent
    return S
end

local function Padding(Parent, T, B, L, R)
    local P = Instance.new("UIPadding")
    P.PaddingTop = UDim.new(0, T)
    P.PaddingBottom = UDim.new(0, B)
    P.PaddingLeft = UDim.new(0, L)
    P.PaddingRight = UDim.new(0, R)
    P.Parent = Parent
    return P
end

local function NewLabel(Parent, Props)
    local L = Instance.new("TextLabel")
    L.BackgroundTransparency = 1
    L.Font = Enum.Font.Gotham
    L.TextColor3 = Theme.TextDim
    L.TextSize = 12
    L.TextXAlignment = Enum.TextXAlignment.Left
    for Key, Value in pairs(Props) do L[Key] = Value end
    L.Parent = Parent
    return L
end

-- ═══════════════════════════ SONIDO ═══════════════════════════

-- IDs de la librería de sonidos de UI de Roblox. Si alguno no carga en
-- tu ejecutor no pasa nada: Play() va en pcall y el resto sigue.
local SoundIds = {
    success = "rbxassetid://6026984224",
    snipe   = "rbxassetid://6026984224",
    error   = "rbxassetid://6042053626",
    info    = "rbxassetid://6042053626",
}

local Settings = {
    Sound = true,
    Toasts = true,
}

local SoundCache = {}
local function PlaySound(Kind)
    if not Settings.Sound then return end
    local Id = SoundIds[Kind]
    if not Id then return end
    local Sound = SoundCache[Id]
    if not Sound or not Sound.Parent then
        Sound = Instance.new("Sound")
        Sound.SoundId = Id
        Sound.Volume = (Kind == "snipe") and 0.75 or 0.45
        Sound.Parent = SoundService
        SoundCache[Id] = Sound
    end
    pcall(function() Sound:Play() end)
end

-- ═══════════════════════════ VENTANA ═══════════════════════════

local WIDTH, HEIGHT = 424, 604
local HEADER_H, TABBAR_H, STATUS_H = 58, 40, 32
local CONTENT_H = HEIGHT - HEADER_H - TABBAR_H - STATUS_H

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local GuiParent = (type(gethui) == "function" and gethui()) or PlayerGui

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HoneyMerchant"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.DisplayOrder = 999
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = GuiParent
pcall(function() if type(protectgui) == "function" then protectgui(ScreenGui) end end)
if Global then Global.HoneyMerchantGui = ScreenGui end

local Root = Instance.new("Frame")
Root.Name = "Root"
Root.Size = UDim2.new(0, WIDTH, 0, HEIGHT)
Root.AnchorPoint = Vector2.new(0.5, 0.5)
Root.Position = UDim2.new(0.5, 0, 0.5, 0)
Root.BackgroundColor3 = Theme.Base
Root.BorderSizePixel = 0
Root.ClipsDescendants = true
Root.Parent = ScreenGui
Corner(Root, 15)
Stroke(Root, Theme.Stroke, 1)

do
    local Scale = Instance.new("UIScale")
    Scale.Scale = IsMobile and 0.78 or 1
    Scale.Parent = Root
end

-- Banda de miel arriba
local Glow = Instance.new("Frame")
Glow.Size = UDim2.new(1, 0, 0, 3)
Glow.BackgroundColor3 = Theme.Honey
Glow.BorderSizePixel = 0
Glow.ZIndex = 5
Glow.Parent = Root
do
    local G = Instance.new("UIGradient")
    G.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.HoneyDeep),
        ColorSequenceKeypoint.new(0.5, Theme.Honey),
        ColorSequenceKeypoint.new(1, Theme.HoneyDeep),
    })
    G.Parent = Glow
end

-- ───────────── Header ─────────────

local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, HEADER_H)
Header.BackgroundColor3 = Theme.Surface
Header.BorderSizePixel = 0
Header.Parent = Root

local IconHolder = Instance.new("Frame")
IconHolder.Size = UDim2.new(0, 34, 0, 34)
IconHolder.Position = UDim2.new(0, 14, 0, 12)
IconHolder.BackgroundColor3 = Theme.Honey
IconHolder.BorderSizePixel = 0
IconHolder.Parent = Header
Corner(IconHolder, 9)

NewLabel(IconHolder, {
    Size = UDim2.new(1, 0, 1, 0),
    Font = Enum.Font.GothamBold, Text = "🍯", TextSize = 18,
    TextColor3 = Theme.TextOnHoney, TextXAlignment = Enum.TextXAlignment.Center,
})

local Title = NewLabel(Header, {
    Position = UDim2.new(0, 58, 0, 11), Size = UDim2.new(1, -160, 0, 19),
    Font = Enum.Font.GothamBold, Text = "Honey Merchant",
    TextColor3 = Theme.Text, TextSize = 16,
})

local Subtitle = NewLabel(Header, {
    Position = UDim2.new(0, 58, 0, 30), Size = UDim2.new(1, -160, 0, 16),
    Text = "cargando...", TextSize = 12,
})

local function HeaderButton(Text, OffsetX)
    local Btn = Instance.new("TextButton")
    Btn.Size = UDim2.new(0, 28, 0, 28)
    Btn.Position = UDim2.new(1, OffsetX, 0, 15)
    Btn.BackgroundColor3 = Theme.SurfaceAlt
    Btn.Font = Enum.Font.GothamBold
    Btn.Text = Text
    Btn.TextColor3 = Theme.TextDim
    Btn.TextSize = 15
    Btn.AutoButtonColor = false
    Btn.Parent = Header
    Corner(Btn, 8)
    Btn.MouseEnter:Connect(function()
        Tween(Btn, Quick, {BackgroundColor3 = Theme.CardHover, TextColor3 = Theme.Text})
    end)
    Btn.MouseLeave:Connect(function()
        Tween(Btn, Quick, {BackgroundColor3 = Theme.SurfaceAlt, TextColor3 = Theme.TextDim})
    end)
    return Btn
end

local CloseButton = HeaderButton("×", -38)
local MinimizeButton = HeaderButton("–", -72)

-- Indicador de sniper vivo en el header (visible aun minimizado)
local SniperDot = Instance.new("Frame")
SniperDot.Size = UDim2.new(0, 8, 0, 8)
SniperDot.Position = UDim2.new(1, -96, 0, 25)
SniperDot.BackgroundColor3 = Theme.TextFaint
SniperDot.BorderSizePixel = 0
SniperDot.Parent = Header
Corner(SniperDot, 4)

-- ───────────── Barra de pestañas ─────────────

local TabBar = Instance.new("Frame")
TabBar.Name = "TabBar"
TabBar.Position = UDim2.new(0, 0, 0, HEADER_H)
TabBar.Size = UDim2.new(1, 0, 0, TABBAR_H)
TabBar.BackgroundColor3 = Theme.Surface
TabBar.BorderSizePixel = 0
TabBar.Parent = Root

local TabDivider = Instance.new("Frame")
TabDivider.Size = UDim2.new(1, 0, 0, 1)
TabDivider.Position = UDim2.new(0, 0, 1, -1)
TabDivider.BackgroundColor3 = Theme.Stroke
TabDivider.BorderSizePixel = 0
TabDivider.Parent = TabBar

local TabIndicator = Instance.new("Frame")
TabIndicator.Size = UDim2.new(0, 0, 0, 2)
TabIndicator.Position = UDim2.new(0, 0, 1, -2)
TabIndicator.BackgroundColor3 = Theme.Honey
TabIndicator.BorderSizePixel = 0
TabIndicator.ZIndex = 2
TabIndicator.Parent = TabBar
Corner(TabIndicator, 1)

-- ───────────── Contenido ─────────────

local Content = Instance.new("Frame")
Content.Name = "Content"
Content.Position = UDim2.new(0, 0, 0, HEADER_H + TABBAR_H)
Content.Size = UDim2.new(1, 0, 0, CONTENT_H)
Content.BackgroundTransparency = 1
Content.ClipsDescendants = true
Content.Parent = Root

-- ───────────── Barra de estado ─────────────

local StatusBar = Instance.new("Frame")
StatusBar.Name = "StatusBar"
StatusBar.Position = UDim2.new(0, 0, 1, -STATUS_H)
StatusBar.Size = UDim2.new(1, 0, 0, STATUS_H)
StatusBar.BackgroundColor3 = Theme.Surface
StatusBar.BorderSizePixel = 0
StatusBar.Parent = Root

local StatusDivider = Instance.new("Frame")
StatusDivider.Size = UDim2.new(1, 0, 0, 1)
StatusDivider.BackgroundColor3 = Theme.Stroke
StatusDivider.BorderSizePixel = 0
StatusDivider.Parent = StatusBar

local Status = NewLabel(StatusBar, {
    Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -28, 1, 0),
    Text = "Cargando productos...", TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd,
})

local function SetStatus(Text, Color)
    Status.Text = Text
    Status.TextColor3 = Color or Theme.TextDim
    Status.TextTransparency = 1
    Tween(Status, Smooth, {TextTransparency = 0})
end

-- ───────────── Pestañas ─────────────

local Tabs, TabButtons = {}, {}
local ActiveTab

local function MakeTab(Name, Order, Total)
    local Page = Instance.new("Frame")
    Page.Name = Name .. "Page"
    Page.Size = UDim2.new(1, 0, 1, 0)
    Page.BackgroundTransparency = 1
    Page.Visible = false
    Page.Parent = Content
    Padding(Page, 12, 12, 12, 12)

    local Layout = Instance.new("UIListLayout")
    Layout.Padding = UDim.new(0, 8)
    Layout.SortOrder = Enum.SortOrder.LayoutOrder
    Layout.Parent = Page

    local Btn = Instance.new("TextButton")
    Btn.Size = UDim2.new(1 / Total, 0, 1, -1)
    Btn.Position = UDim2.new((Order - 1) / Total, 0, 0, 0)
    Btn.BackgroundTransparency = 1
    Btn.Font = Enum.Font.GothamBold
    Btn.Text = Name
    Btn.TextColor3 = Theme.TextFaint
    Btn.TextSize = 12
    Btn.AutoButtonColor = false
    Btn.Parent = TabBar

    Tabs[Name] = Page
    TabButtons[Name] = Btn

    Btn.MouseButton1Click:Connect(function()
        if ActiveTab == Name then return end
        for OtherName, OtherPage in pairs(Tabs) do
            OtherPage.Visible = false
            Tween(TabButtons[OtherName], Quick, {TextColor3 = Theme.TextFaint})
        end
        Page.Visible = true
        ActiveTab = Name
        Tween(Btn, Quick, {TextColor3 = Theme.Honey})
        Tween(TabIndicator, Smooth, {
            Position = UDim2.new((Order - 1) / Total, 12, 1, -2),
            Size = UDim2.new(1 / Total, -24, 0, 2),
        })
    end)

    return Page, Btn
end

local TAB_COUNT = 4
local ShopPage = MakeTab("Tienda", 1, TAB_COUNT)
local SniperPage = MakeTab("Sniper", 2, TAB_COUNT)
local LogPage = MakeTab("Log", 3, TAB_COUNT)
local StatsPage = MakeTab("Stats", 4, TAB_COUNT)

local function ShowTab(Name)
    for OtherName, OtherPage in pairs(Tabs) do
        OtherPage.Visible = (OtherName == Name)
        TabButtons[OtherName].TextColor3 = (OtherName == Name) and Theme.Honey or Theme.TextFaint
    end
    ActiveTab = Name
end

-- ═══════════════════════════ TOASTS ═══════════════════════════

local ToastHolder = Instance.new("Frame")
ToastHolder.Name = "Toasts"
ToastHolder.AnchorPoint = Vector2.new(1, 0)
ToastHolder.Position = UDim2.new(1, -16, 0, 16)
ToastHolder.Size = UDim2.new(0, 300, 1, -32)
ToastHolder.BackgroundTransparency = 1
ToastHolder.Parent = ScreenGui

local ToastLayout = Instance.new("UIListLayout")
ToastLayout.Padding = UDim.new(0, 8)
ToastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
ToastLayout.SortOrder = Enum.SortOrder.LayoutOrder
ToastLayout.Parent = ToastHolder

local ToastSeq = 0
local ToastKinds = {
    success = {Color = Theme.Success, Icon = "✓"},
    error   = {Color = Theme.Error,   Icon = "✗"},
    warning = {Color = Theme.Warning, Icon = "!"},
    info    = {Color = Theme.Info,    Icon = "i"},
    snipe   = {Color = Theme.Honey,   Icon = "🎯"},
}

local function Notify(TitleText, BodyText, Kind, Silent)
    if not Silent then PlaySound(Kind) end
    if not Settings.Toasts then return end

    local Style = ToastKinds[Kind] or ToastKinds.info
    ToastSeq = ToastSeq + 1

    -- El shell tiene el alto animado y recorta: así el toast "crece"
    -- dentro del UIListLayout en vez de pelearse con su posición.
    local Shell = Instance.new("Frame")
    Shell.Name = "Toast"
    Shell.Size = UDim2.new(0, 296, 0, 0)
    Shell.BackgroundTransparency = 1
    Shell.ClipsDescendants = true
    Shell.LayoutOrder = ToastSeq
    Shell.Parent = ToastHolder

    local Card = Instance.new("Frame")
    Card.Size = UDim2.new(1, 0, 0, 58)
    Card.BackgroundColor3 = Theme.Surface
    Card.BackgroundTransparency = 0.05
    Card.BorderSizePixel = 0
    Card.Parent = Shell
    Corner(Card, 10)
    Stroke(Card, Style.Color, 1, 0.5)

    local Accent = Instance.new("Frame")
    Accent.Size = UDim2.new(0, 3, 1, -16)
    Accent.Position = UDim2.new(0, 8, 0, 8)
    Accent.BackgroundColor3 = Style.Color
    Accent.BorderSizePixel = 0
    Accent.Parent = Card
    Corner(Accent, 2)

    NewLabel(Card, {
        Position = UDim2.new(0, 18, 0, 9), Size = UDim2.new(0, 22, 0, 20),
        Font = Enum.Font.GothamBold, Text = Style.Icon, TextSize = 14,
        TextColor3 = Style.Color,
    })

    local ToastTitle = NewLabel(Card, {
        Position = UDim2.new(0, 42, 0, 9), Size = UDim2.new(1, -54, 0, 20),
        Font = Enum.Font.GothamBold, Text = TitleText, TextSize = 13,
        TextColor3 = Theme.Text, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    local ToastBody = NewLabel(Card, {
        Position = UDim2.new(0, 42, 0, 29), Size = UDim2.new(1, -54, 0, 20),
        Text = BodyText or "", TextSize = 11,
        TextColor3 = Theme.TextDim, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    Tween(Shell, Smooth, {Size = UDim2.new(0, 296, 0, 58)})

    task.delay(3.4, function()
        if not Shell.Parent then return end
        Tween(Card, Quick, {BackgroundTransparency = 1})
        Tween(ToastTitle, Quick, {TextTransparency = 1})
        Tween(ToastBody, Quick, {TextTransparency = 1})
        Tween(Accent, Quick, {BackgroundTransparency = 1})
        Tween(Shell, Smooth, {Size = UDim2.new(0, 296, 0, 0)})
        task.delay(0.32, function() Shell:Destroy() end)
    end)
end

-- ═══════════════════════════ HISTORIAL ═══════════════════════════

local LogList, LogSummary
local LogRows, LogSeq = {}, 0

local function RenderLogEntry(Entry)
    if not LogList then return end
    LogSeq = LogSeq + 1

    local Row = Instance.new("Frame")
    Row.Size = UDim2.new(1, -6, 0, 44)
    Row.BackgroundColor3 = Theme.Card
    Row.BorderSizePixel = 0
    Row.LayoutOrder = -LogSeq -- lo más nuevo, arriba
    Row.Parent = LogList
    Corner(Row, 8)

    local Tone = Entry.OK and Theme.Success or (Entry.Partial and Theme.Warning or Theme.Error)

    local Accent = Instance.new("Frame")
    Accent.Size = UDim2.new(0, 3, 0, 26)
    Accent.Position = UDim2.new(0, 8, 0.5, -13)
    Accent.BackgroundColor3 = Tone
    Accent.BorderSizePixel = 0
    Accent.Parent = Row
    Corner(Accent, 2)

    NewLabel(Row, {
        Position = UDim2.new(0, 18, 0, 5), Size = UDim2.new(1, -110, 0, 17),
        Font = Enum.Font.GothamBold, Text = string.format("%s × %d", Entry.Name, Entry.Amount),
        TextSize = 12, TextColor3 = Theme.Text, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    NewLabel(Row, {
        Position = UDim2.new(0, 18, 0, 22), Size = UDim2.new(1, -110, 0, 16),
        Text = string.format("%s · %s · %s", Entry.Clock, Entry.Source, Entry.Message or ""),
        TextSize = 10, TextColor3 = Theme.TextFaint, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    NewLabel(Row, {
        Position = UDim2.new(1, -98, 0, 5), Size = UDim2.new(0, 90, 0, 17),
        Font = Enum.Font.GothamBold, Text = string.format("%s 🍯", Comma(Entry.Cost)),
        TextSize = 12, TextColor3 = Tone, TextXAlignment = Enum.TextXAlignment.Right,
    })

    NewLabel(Row, {
        Position = UDim2.new(1, -98, 0, 22), Size = UDim2.new(0, 90, 0, 16),
        Text = Entry.Bought .. "/" .. Entry.Amount, TextSize = 10,
        TextColor3 = Theme.TextFaint, TextXAlignment = Enum.TextXAlignment.Right,
    })

    table.insert(LogRows, Row)
    while #LogRows > HISTORY_MAX do
        local Oldest = table.remove(LogRows, 1)
        if Oldest then Oldest:Destroy() end
    end

    if LogSummary then
        LogSummary.Text = string.format("%d registros", #History)
    end
end

local function PushHistory(Entry)
    table.insert(History, Entry)
    while #History > HISTORY_MAX do table.remove(History, 1) end
    RenderLogEntry(Entry)
end

-- ═══════════════════════════ MOTOR DE COMPRA ═══════════════════════════

local StatLabels = {}
local RefreshStats -- se define con la pestaña Stats

-- Un solo camino para toda compra (manual o sniper): ejecuta, mide,
-- registra en el historial, actualiza stats y notifica. Sin delay entre
-- unidades — InvokeServer ya se bloquea esperando al servidor, y
-- firesignal invoca el handler del juego en el acto.
local function ExecutePurchase(Product, Amount, Source, WaitedSeconds)
    local Bought, LastMessage = 0, nil
    for _ = 1, Amount do
        local OK, Message = Buy(Product)
        LastMessage = Message
        Stats.Attempts = Stats.Attempts + 1
        if not OK then
            Stats.Fails = Stats.Fails + 1
            break
        end
        Bought = Bought + 1
    end

    local Cost = Bought * Product.Price
    Stats.Items = Stats.Items + Bought
    Stats.Spent = Stats.Spent + Cost

    if Source == "sniper" and Bought > 0 then
        Stats.Snipes = Stats.Snipes + Bought
        if WaitedSeconds then
            Stats.SnipeWaits = Stats.SnipeWaits + WaitedSeconds
            Stats.SnipeCount = Stats.SnipeCount + 1
        end
    end

    PushHistory({
        Name = Product.Name,
        Amount = Amount,
        Bought = Bought,
        Cost = Cost,
        OK = (Bought == Amount),
        Partial = (Bought > 0 and Bought < Amount),
        Source = Source,
        Message = LastMessage,
        Clock = os.date("%H:%M:%S"),
    })

    if RefreshStats then RefreshStats() end

    if Bought == Amount then
        Notify(
            string.format("%s × %d", Product.Name, Bought),
            string.format("%s 🍯%s", Comma(Cost), WaitedSeconds and string.format(" · esperó %s", ShortTime(WaitedSeconds)) or ""),
            Source == "sniper" and "snipe" or "success"
        )
    elseif Bought > 0 then
        Notify(
            string.format("%s × %d de %d", Product.Name, Bought, Amount),
            tostring(LastMessage), "warning"
        )
    else
        Notify(Product.Name, tostring(LastMessage), "error")
    end

    return Bought, LastMessage
end

-- ═══════════════════════════ PESTAÑA: TIENDA ═══════════════════════════

local List = Instance.new("ScrollingFrame")
List.Name = "List"
List.LayoutOrder = 1
List.Size = UDim2.new(1, 0, 0, 230)
List.BackgroundTransparency = 1
List.BorderSizePixel = 0
List.ScrollBarThickness = 3
List.ScrollBarImageColor3 = Theme.Honey
List.ScrollBarImageTransparency = 0.3
List.AutomaticCanvasSize = Enum.AutomaticSize.Y
List.CanvasSize = UDim2.new(0, 0, 0, 0)
List.Parent = ShopPage

local ListLayout = Instance.new("UIListLayout")
ListLayout.Padding = UDim.new(0, 7)
ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListLayout.Parent = List

local Detail = Instance.new("Frame")
Detail.Name = "Detail"
Detail.LayoutOrder = 2
Detail.Size = UDim2.new(1, 0, 0, 60)
Detail.BackgroundColor3 = Theme.Surface
Detail.BorderSizePixel = 0
Detail.Parent = ShopPage
Corner(Detail, 10)
Stroke(Detail, Theme.Stroke, 1, 0.4)

local DetailName = NewLabel(Detail, {
    Position = UDim2.new(0, 12, 0, 9), Size = UDim2.new(1, -24, 0, 18),
    Font = Enum.Font.GothamBold, Text = "Ningún producto elegido",
    TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
})

local DetailMeta = NewLabel(Detail, {
    Position = UDim2.new(0, 12, 0, 30), Size = UDim2.new(1, -24, 0, 18),
    Text = "Tocá un item de la lista de arriba", TextSize = 12,
})

-- Cantidad
local QtyRow = Instance.new("Frame")
QtyRow.LayoutOrder = 3
QtyRow.Size = UDim2.new(1, 0, 0, 38)
QtyRow.BackgroundColor3 = Theme.Surface
QtyRow.BorderSizePixel = 0
QtyRow.Parent = ShopPage
Corner(QtyRow, 10)
Stroke(QtyRow, Theme.Stroke, 1, 0.4)

NewLabel(QtyRow, {
    Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(0, 120, 1, 0),
    Text = "Cantidad", TextSize = 13,
})

local function StepButton(Parent, Text, OffsetX, Size)
    local Btn = Instance.new("TextButton")
    Btn.Size = UDim2.new(0, Size or 28, 0, Size or 28)
    Btn.Position = UDim2.new(1, OffsetX, 0.5, -(Size or 28) / 2)
    Btn.BackgroundColor3 = Theme.Card
    Btn.Font = Enum.Font.GothamBold
    Btn.Text = Text
    Btn.TextColor3 = Theme.Text
    Btn.TextSize = (Size and Size < 28) and 14 or 17
    Btn.AutoButtonColor = false
    Btn.Parent = Parent
    Corner(Btn, 8)
    Btn.MouseEnter:Connect(function() Tween(Btn, Quick, {BackgroundColor3 = Theme.Honey, TextColor3 = Theme.TextOnHoney}) end)
    Btn.MouseLeave:Connect(function() Tween(Btn, Quick, {BackgroundColor3 = Theme.Card, TextColor3 = Theme.Text}) end)
    return Btn
end

local MinusBtn = StepButton(QtyRow, "−", -102)
local PlusBtn = StepButton(QtyRow, "+", -40)

local QtyValue = NewLabel(QtyRow, {
    Position = UDim2.new(1, -74, 0, 0), Size = UDim2.new(0, 34, 1, 0),
    Font = Enum.Font.GothamBold, Text = "1", TextSize = 15,
    TextColor3 = Theme.Honey, TextXAlignment = Enum.TextXAlignment.Center,
})

-- Método
local MethodRow = Instance.new("TextButton")
MethodRow.LayoutOrder = 4
MethodRow.Size = UDim2.new(1, 0, 0, 38)
MethodRow.BackgroundColor3 = Theme.Surface
MethodRow.BorderSizePixel = 0
MethodRow.AutoButtonColor = false
MethodRow.Text = ""
MethodRow.Parent = ShopPage
Corner(MethodRow, 10)
Stroke(MethodRow, Theme.Stroke, 1, 0.4)

NewLabel(MethodRow, {
    Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -140, 1, 0),
    Text = "Método", TextSize = 13,
})

local MethodValue = NewLabel(MethodRow, {
    Position = UDim2.new(1, -132, 0, 0), Size = UDim2.new(0, 120, 1, 0),
    Font = Enum.Font.GothamBold, Text = "UI del juego", TextSize = 12,
    TextColor3 = Theme.Honey, TextXAlignment = Enum.TextXAlignment.Right,
})

-- Comprar
local BuyBtn = Instance.new("TextButton")
BuyBtn.LayoutOrder = 5
BuyBtn.Size = UDim2.new(1, 0, 0, 46)
BuyBtn.BackgroundColor3 = Theme.Honey
BuyBtn.Font = Enum.Font.GothamBold
BuyBtn.Text = "Comprar"
BuyBtn.TextColor3 = Theme.TextOnHoney
BuyBtn.TextSize = 15
BuyBtn.AutoButtonColor = false
BuyBtn.Parent = ShopPage
Corner(BuyBtn, 10)
do
    local G = Instance.new("UIGradient")
    G.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.Honey),
        ColorSequenceKeypoint.new(1, Theme.HoneyDeep),
    })
    G.Rotation = 90
    G.Parent = BuyBtn
end

-- ═══════════════════════════ PESTAÑA: SNIPER ═══════════════════════════

local function ToggleRow(Parent, Order, TitleText, HintText, Height)
    local Row = Instance.new("TextButton")
    Row.LayoutOrder = Order
    Row.Size = UDim2.new(1, 0, 0, Height or 44)
    Row.BackgroundColor3 = Theme.Surface
    Row.BorderSizePixel = 0
    Row.AutoButtonColor = false
    Row.Text = ""
    Row.Parent = Parent
    Corner(Row, 10)
    Stroke(Row, Theme.Stroke, 1, 0.4)

    local Label = NewLabel(Row, {
        Position = UDim2.new(0, 12, 0, HintText and 6 or 0),
        Size = UDim2.new(1, -80, 0, HintText and 18 or (Height or 44)),
        Font = Enum.Font.GothamBold, Text = TitleText, TextSize = 13,
    })

    local Hint
    if HintText then
        Hint = NewLabel(Row, {
            Position = UDim2.new(0, 12, 0, 24), Size = UDim2.new(1, -80, 0, 15),
            Text = HintText, TextSize = 10, TextColor3 = Theme.TextFaint,
        })
    end

    local Track = Instance.new("Frame")
    Track.Size = UDim2.new(0, 42, 0, 22)
    Track.Position = UDim2.new(1, -54, 0.5, -11)
    Track.BackgroundColor3 = Theme.Card
    Track.BorderSizePixel = 0
    Track.Parent = Row
    Corner(Track, 11)

    local Knob = Instance.new("Frame")
    Knob.Size = UDim2.new(0, 16, 0, 16)
    Knob.Position = UDim2.new(0, 3, 0.5, -8)
    Knob.BackgroundColor3 = Theme.TextDim
    Knob.BorderSizePixel = 0
    Knob.Parent = Track
    Corner(Knob, 8)

    local function Paint(On)
        if On then
            Tween(Track, Quick, {BackgroundColor3 = Theme.Honey})
            Tween(Knob, Quick, {Position = UDim2.new(0, 23, 0.5, -8), BackgroundColor3 = Theme.TextOnHoney})
            Label.TextColor3 = Theme.Honey
        else
            Tween(Track, Quick, {BackgroundColor3 = Theme.Card})
            Tween(Knob, Quick, {Position = UDim2.new(0, 3, 0.5, -8), BackgroundColor3 = Theme.TextDim})
            Label.TextColor3 = Theme.TextDim
        end
    end

    return Row, Paint, Label, Hint
end

local SniperRow, PaintSniper, _SniperLabel, SniperHint =
    ToggleRow(SniperPage, 1, "Sniper", "compra sola apenas haya stock", 50)

local TargetsBox = Instance.new("Frame")
TargetsBox.LayoutOrder = 2
TargetsBox.Size = UDim2.new(1, 0, 0, 290)
TargetsBox.BackgroundColor3 = Theme.Surface
TargetsBox.BorderSizePixel = 0
TargetsBox.Parent = SniperPage
Corner(TargetsBox, 10)
Stroke(TargetsBox, Theme.Stroke, 1, 0.4)

NewLabel(TargetsBox, {
    Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 16),
    Font = Enum.Font.GothamBold, Text = "OBJETIVOS", TextSize = 10,
    TextColor3 = Theme.TextFaint,
})

local TargetsCount = NewLabel(TargetsBox, {
    Position = UDim2.new(1, -84, 0, 8), Size = UDim2.new(0, 72, 0, 16),
    Text = "0", TextSize = 10, TextColor3 = Theme.TextFaint,
    TextXAlignment = Enum.TextXAlignment.Right,
})

local TargetsList = Instance.new("ScrollingFrame")
TargetsList.Position = UDim2.new(0, 8, 0, 28)
TargetsList.Size = UDim2.new(1, -16, 1, -36)
TargetsList.BackgroundTransparency = 1
TargetsList.BorderSizePixel = 0
TargetsList.ScrollBarThickness = 3
TargetsList.ScrollBarImageColor3 = Theme.Honey
TargetsList.ScrollBarImageTransparency = 0.3
TargetsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
TargetsList.CanvasSize = UDim2.new(0, 0, 0, 0)
TargetsList.Parent = TargetsBox

local TargetsLayout = Instance.new("UIListLayout")
TargetsLayout.Padding = UDim.new(0, 6)
TargetsLayout.SortOrder = Enum.SortOrder.LayoutOrder
TargetsLayout.Parent = TargetsList

local EmptyHint = NewLabel(TargetsList, {
    Size = UDim2.new(1, -6, 0, 60), Text = "Marcá productos con 🎯 en la pestaña Tienda.\nEl sniper los compra a todos apenas aparezca stock.",
    TextSize = 11, TextColor3 = Theme.TextFaint, TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 999,
})

local SoundRow, PaintSound = ToggleRow(SniperPage, 3, "Sonido", "avisa al comprar o fallar", 42)
local ToastRow, PaintToast = ToggleRow(SniperPage, 4, "Notificaciones", "tarjetas flotantes en pantalla", 42)

-- ═══════════════════════════ PESTAÑA: LOG ═══════════════════════════

local LogHead = Instance.new("Frame")
LogHead.LayoutOrder = 1
LogHead.Size = UDim2.new(1, 0, 0, 34)
LogHead.BackgroundColor3 = Theme.Surface
LogHead.BorderSizePixel = 0
LogHead.Parent = LogPage
Corner(LogHead, 9)

NewLabel(LogHead, {
    Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -120, 1, 0),
    Font = Enum.Font.GothamBold, Text = "HISTORIAL DE COMPRAS", TextSize = 10,
    TextColor3 = Theme.TextFaint,
})

LogSummary = NewLabel(LogHead, {
    Position = UDim2.new(1, -104, 0, 0), Size = UDim2.new(0, 92, 1, 0),
    Text = "0 registros", TextSize = 10, TextColor3 = Theme.TextFaint,
    TextXAlignment = Enum.TextXAlignment.Right,
})

LogList = Instance.new("ScrollingFrame")
LogList.LayoutOrder = 2
LogList.Size = UDim2.new(1, 0, 0, 366)
LogList.BackgroundTransparency = 1
LogList.BorderSizePixel = 0
LogList.ScrollBarThickness = 3
LogList.ScrollBarImageColor3 = Theme.Honey
LogList.ScrollBarImageTransparency = 0.3
LogList.AutomaticCanvasSize = Enum.AutomaticSize.Y
LogList.CanvasSize = UDim2.new(0, 0, 0, 0)
LogList.Parent = LogPage

local LogListLayout = Instance.new("UIListLayout")
LogListLayout.Padding = UDim.new(0, 6)
LogListLayout.SortOrder = Enum.SortOrder.LayoutOrder
LogListLayout.Parent = LogList

local ClearLogBtn = Instance.new("TextButton")
ClearLogBtn.LayoutOrder = 3
ClearLogBtn.Size = UDim2.new(1, 0, 0, 32)
ClearLogBtn.BackgroundColor3 = Theme.Surface
ClearLogBtn.Font = Enum.Font.GothamBold
ClearLogBtn.Text = "Vaciar historial"
ClearLogBtn.TextColor3 = Theme.TextDim
ClearLogBtn.TextSize = 12
ClearLogBtn.AutoButtonColor = false
ClearLogBtn.Parent = LogPage
Corner(ClearLogBtn, 9)
Stroke(ClearLogBtn, Theme.Stroke, 1, 0.4)

-- ═══════════════════════════ PESTAÑA: STATS ═══════════════════════════

local StatsGrid = Instance.new("Frame")
StatsGrid.LayoutOrder = 1
StatsGrid.Size = UDim2.new(1, 0, 0, 288)
StatsGrid.BackgroundTransparency = 1
StatsGrid.Parent = StatsPage

local GridLayout = Instance.new("UIGridLayout")
GridLayout.CellSize = UDim2.new(0.5, -4, 0, 66)
GridLayout.CellPadding = UDim2.new(0, 8, 0, 8)
GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
GridLayout.Parent = StatsGrid

local function StatCard(Key, Caption, Order, Color)
    local Card = Instance.new("Frame")
    Card.BackgroundColor3 = Theme.Surface
    Card.BorderSizePixel = 0
    Card.LayoutOrder = Order
    Card.Parent = StatsGrid
    Corner(Card, 10)
    Stroke(Card, Theme.Stroke, 1, 0.5)

    NewLabel(Card, {
        Position = UDim2.new(0, 12, 0, 9), Size = UDim2.new(1, -24, 0, 14),
        Text = Caption:upper(), TextSize = 9, TextColor3 = Theme.TextFaint,
    })

    StatLabels[Key] = NewLabel(Card, {
        Position = UDim2.new(0, 12, 0, 25), Size = UDim2.new(1, -24, 0, 30),
        Font = Enum.Font.GothamBold, Text = "0", TextSize = 20,
        TextColor3 = Color or Theme.Text, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    return Card
end

StatCard("Items",   "comprados",       1, Theme.Success)
StatCard("Spent",   "gastado 🍯",      2, Theme.Honey)
StatCard("Snipes",  "sniped",          3, Theme.Honey)
StatCard("Rate",    "tasa de éxito",   4, Theme.Info)
StatCard("Attempts","intentos",        5)
StatCard("Fails",   "fallos",          6, Theme.Error)
StatCard("AvgWait", "espera media",    7)
StatCard("Uptime",  "sesión",          8)

local RateBox = Instance.new("Frame")
RateBox.LayoutOrder = 2
RateBox.Size = UDim2.new(1, 0, 0, 56)
RateBox.BackgroundColor3 = Theme.Surface
RateBox.BorderSizePixel = 0
RateBox.Parent = StatsPage
Corner(RateBox, 10)
Stroke(RateBox, Theme.Stroke, 1, 0.5)

NewLabel(RateBox, {
    Position = UDim2.new(0, 12, 0, 9), Size = UDim2.new(1, -24, 0, 14),
    Text = "ÉXITO DE COMPRAS", TextSize = 9, TextColor3 = Theme.TextFaint,
})

local RateTrack = Instance.new("Frame")
RateTrack.Position = UDim2.new(0, 12, 0, 30)
RateTrack.Size = UDim2.new(1, -24, 0, 10)
RateTrack.BackgroundColor3 = Theme.Card
RateTrack.BorderSizePixel = 0
RateTrack.Parent = RateBox
Corner(RateTrack, 5)

local RateFill = Instance.new("Frame")
RateFill.Size = UDim2.new(0, 0, 1, 0)
RateFill.BackgroundColor3 = Theme.Success
RateFill.BorderSizePixel = 0
RateFill.Parent = RateTrack
Corner(RateFill, 5)

-- Qué capas del patch de entorno agarraron en este ejecutor
local EnvBox = Instance.new("Frame")
EnvBox.LayoutOrder = 3
EnvBox.Size = UDim2.new(1, 0, 0, 44)
EnvBox.BackgroundColor3 = Theme.Surface
EnvBox.BorderSizePixel = 0
EnvBox.Parent = StatsPage
Corner(EnvBox, 10)
Stroke(EnvBox, Theme.Stroke, 1, 0.5)

NewLabel(EnvBox, {
    Position = UDim2.new(0, 12, 0, 7), Size = UDim2.new(1, -24, 0, 14),
    Text = "PATCH DE ENTORNO", TextSize = 9, TextColor3 = Theme.TextFaint,
})

do
    local Report = Env.Report
    local Parts = {
        string.format("espejo: %s%s", Report.Mirror, Report.Host and (" (" .. Report.Host .. ")") or ""),
        "fenv: " .. (Report.Fenv and "✓" or "✗"),
        "identidad: " .. (Report.Identity and "✓" or "✗"),
        "hilo: ✓",
    }
    local Complete = Report.Fenv and Report.Identity and Report.Mirror ~= "ninguno"
    NewLabel(EnvBox, {
        Position = UDim2.new(0, 12, 0, 22), Size = UDim2.new(1, -24, 0, 16),
        Text = table.concat(Parts, "  ·  "), TextSize = 10,
        TextColor3 = Complete and Theme.Success or Theme.Warning,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
end

local ResetStatsBtn = Instance.new("TextButton")
ResetStatsBtn.LayoutOrder = 4
ResetStatsBtn.Size = UDim2.new(1, 0, 0, 34)
ResetStatsBtn.BackgroundColor3 = Theme.Surface
ResetStatsBtn.Font = Enum.Font.GothamBold
ResetStatsBtn.Text = "Reiniciar estadísticas"
ResetStatsBtn.TextColor3 = Theme.TextDim
ResetStatsBtn.TextSize = 12
ResetStatsBtn.AutoButtonColor = false
ResetStatsBtn.Parent = StatsPage
Corner(ResetStatsBtn, 9)
Stroke(ResetStatsBtn, Theme.Stroke, 1, 0.4)

RefreshStats = function()
    StatLabels.Items.Text = Comma(Stats.Items)
    StatLabels.Spent.Text = Comma(Stats.Spent)
    StatLabels.Snipes.Text = Comma(Stats.Snipes)
    StatLabels.Attempts.Text = Comma(Stats.Attempts)
    StatLabels.Fails.Text = Comma(Stats.Fails)

    local Rate = (Stats.Attempts > 0) and ((Stats.Attempts - Stats.Fails) / Stats.Attempts) or 0
    StatLabels.Rate.Text = string.format("%.0f%%", Rate * 100)
    Tween(RateFill, Smooth, {
        Size = UDim2.new(Rate, 0, 1, 0),
        BackgroundColor3 = (Rate >= 0.8 and Theme.Success) or (Rate >= 0.4 and Theme.Warning) or Theme.Error,
    })

    StatLabels.AvgWait.Text = (Stats.SnipeCount > 0)
        and ShortTime(Stats.SnipeWaits / Stats.SnipeCount) or "—"
    StatLabels.Uptime.Text = ShortTime(os.clock() - Stats.StartedAt)
end

-- ═══════════════════════════ INTERACCIÓN ═══════════════════════════

do -- arrastre
    local Dragging, DragStart, StartPos
    local function Begin(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
            Dragging = true
            DragStart = Input.Position
            StartPos = Root.Position
            local Conn
            Conn = Input.Changed:Connect(function()
                if Input.UserInputState == Enum.UserInputState.End then
                    Dragging = false
                    Conn:Disconnect()
                end
            end)
        end
    end
    Header.InputBegan:Connect(Begin)
    Title.InputBegan:Connect(Begin)
    UserInputService.InputChanged:Connect(function(Input)
        if Dragging and (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch) then
            local Delta = Input.Position - DragStart
            Root.Position = UDim2.new(StartPos.X.Scale, StartPos.X.Offset + Delta.X, StartPos.Y.Scale, StartPos.Y.Offset + Delta.Y)
        end
    end)
end

CloseButton.MouseButton1Click:Connect(function()
    Tween(Root, Quick, {Size = UDim2.new(0, WIDTH, 0, 0)})
    task.delay(0.2, function() ScreenGui:Destroy() end)
end)

local Minimized = false
MinimizeButton.MouseButton1Click:Connect(function()
    Minimized = not Minimized
    Tween(Root, Smooth, {Size = Minimized and UDim2.new(0, WIDTH, 0, HEADER_H) or UDim2.new(0, WIDTH, 0, HEIGHT)})
    MinimizeButton.Text = Minimized and "+" or "–"
end)

MethodRow.MouseButton1Click:Connect(function()
    UseGameUI = not UseGameUI
    MethodValue.Text = UseGameUI and "UI del juego" or "Remoto directo"
    SetStatus(UseGameUI
        and "UI del juego: aprieta el botón real de la tienda (necesita la tienda abierta)"
        or "Remoto directo: InvokeServer a BeeMerchantService/Buy", Theme.TextDim)
end)

SoundRow.MouseButton1Click:Connect(function()
    Settings.Sound = not Settings.Sound
    PaintSound(Settings.Sound)
    if Settings.Sound then PlaySound("info") end
end)

ToastRow.MouseButton1Click:Connect(function()
    Settings.Toasts = not Settings.Toasts
    PaintToast(Settings.Toasts)
    if Settings.Toasts then Notify("Notificaciones", "activadas", "info", true) end
end)

ClearLogBtn.MouseButton1Click:Connect(function()
    table.clear(History)
    for _, Row in ipairs(LogRows) do Row:Destroy() end
    table.clear(LogRows)
    LogSummary.Text = "0 registros"
    SetStatus("Historial vaciado", Theme.TextDim)
end)

ResetStatsBtn.MouseButton1Click:Connect(function()
    Stats.Items, Stats.Spent, Stats.Attempts, Stats.Fails = 0, 0, 0, 0
    Stats.Snipes, Stats.SnipeWaits, Stats.SnipeCount = 0, 0, 0
    Stats.StartedAt = os.clock()
    RefreshStats()
    SetStatus("Estadísticas reiniciadas", Theme.TextDim)
end)

for _, Btn in ipairs({ClearLogBtn, ResetStatsBtn}) do
    Btn.MouseEnter:Connect(function() Tween(Btn, Quick, {BackgroundColor3 = Theme.Card, TextColor3 = Theme.Text}) end)
    Btn.MouseLeave:Connect(function() Tween(Btn, Quick, {BackgroundColor3 = Theme.Surface, TextColor3 = Theme.TextDim}) end)
end

-- Estado de la tienda

local Quantity = 1
local Selected, SelectedCard = nil, nil
local CardStrokes, CardsByProduct = {}, {}

local function RefreshBuyLabel()
    if Selected then
        BuyBtn.Text = string.format("Comprar  ·  %s 🍯", Comma(Selected.Price * Quantity))
    else
        BuyBtn.Text = "Comprar"
    end
end

local function RefreshDetail()
    if not Selected then return end
    DetailName.Text = Selected.Name
    DetailName.TextColor3 = Theme.Text

    -- Stock del catálogo (BeeMerchantData) es un tope de config, no lo
    -- que queda en verdad. Si la tienda está abierta, chequeamos el
    -- estado real del botón en vez de confiar en ese número.
    local Live = CheckStock(Selected)
    local StockText
    if Live == true then
        StockText = "EN STOCK"
    elseif Live == false then
        StockText = "SIN STOCK"
    else
        StockText = string.format("tope config. %s", Comma(Selected.Stock))
    end

    DetailMeta.Text = string.format("%s 🍯 c/u   ·   %s   ·   R$ %d",
        Comma(Selected.Price), StockText, Selected.RobuxPrice)
    DetailMeta.TextColor3 = (Live == false) and Theme.Error
        or (Live == true) and Theme.Success or Theme.TextDim
end

local function SetQuantity(Value)
    Quantity = math.clamp(Value, 1, 50)
    QtyValue.Text = tostring(Quantity)
    RefreshBuyLabel()
end

MinusBtn.MouseButton1Click:Connect(function() SetQuantity(Quantity - 1) end)
PlusBtn.MouseButton1Click:Connect(function() SetQuantity(Quantity + 1) end)

BuyBtn.MouseEnter:Connect(function() Tween(BuyBtn, Quick, {Size = UDim2.new(1, 0, 0, 48)}) end)
BuyBtn.MouseLeave:Connect(function() Tween(BuyBtn, Quick, {Size = UDim2.new(1, 0, 0, 46)}) end)

local Busy = false
BuyBtn.MouseButton1Click:Connect(function()
    if Busy then return end
    if not Selected then
        SetStatus("Elegí un producto de la lista primero", Theme.Warning)
        return
    end

    Busy = true
    local Product, Name, Amount = Selected, Selected.Name, Quantity
    BuyBtn.Text = "Comprando..."
    SetStatus(string.format("Comprando %d × %s...", Amount, Name), Theme.TextDim)

    task.spawn(function()
        local Bought, Message = ExecutePurchase(Product, Amount, "manual")

        if Bought == Amount then
            SetStatus(string.format("✓ %s × %d", Name, Bought), Theme.Success)
        elseif Bought > 0 then
            SetStatus(string.format("%s: %d de %d — %s", Name, Bought, Amount, tostring(Message)), Theme.Warning)
        else
            SetStatus(string.format("✗ %s — %s", Name, tostring(Message)), Theme.Error)
        end

        Busy = false
        RefreshBuyLabel()
    end)
end)

-- ═══════════════════════════ SNIPER MULTI-OBJETIVO ═══════════════════════════

-- Cada objetivo lleva su propia cantidad y su propio reloj de espera
-- (WatchSince), que se reinicia cada vez que el producto se queda sin
-- stock. Así "espera media" mide lo que de verdad tardó el restock.
local Sniper = { Enabled = false, LastState = nil }
local Targets, TargetByName = {}, {}

local function RefreshTargetsHeader()
    TargetsCount.Text = (#Targets == 1) and "1 objetivo" or (#Targets .. " objetivos")
    EmptyHint.Visible = (#Targets == 0)
end

local UpdateCardTargetVisual -- lo define BuildCard

local function RemoveTarget(Name)
    local Target = TargetByName[Name]
    if not Target then return end
    Target.Row:Destroy()
    TargetByName[Name] = nil
    for Index, Other in ipairs(Targets) do
        if Other == Target then table.remove(Targets, Index); break end
    end
    RefreshTargetsHeader()
    if UpdateCardTargetVisual then UpdateCardTargetVisual(Name) end
    Sniper.LastState = nil
end

local function AddTarget(Product)
    if TargetByName[Product.Name] then return end

    local Row = Instance.new("Frame")
    Row.Size = UDim2.new(1, -6, 0, 46)
    Row.BackgroundColor3 = Theme.Card
    Row.BorderSizePixel = 0
    Row.LayoutOrder = #Targets + 1
    Row.Parent = TargetsList
    Corner(Row, 8)

    local Dot = Instance.new("Frame")
    Dot.Size = UDim2.new(0, 8, 0, 8)
    Dot.Position = UDim2.new(0, 10, 0.5, -4)
    Dot.BackgroundColor3 = Theme.TextFaint
    Dot.BorderSizePixel = 0
    Dot.Parent = Row
    Corner(Dot, 4)

    NewLabel(Row, {
        Position = UDim2.new(0, 26, 0, 6), Size = UDim2.new(1, -140, 0, 17),
        Font = Enum.Font.GothamBold, Text = Product.Name, TextSize = 12,
        TextColor3 = Theme.Text, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    local StateLabel = NewLabel(Row, {
        Position = UDim2.new(0, 26, 0, 23), Size = UDim2.new(1, -140, 0, 16),
        Text = "en espera", TextSize = 10, TextColor3 = Theme.TextFaint,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })

    local Remove = StepButton(Row, "×", -32, 24)
    local AmountPlus = StepButton(Row, "+", -62, 24)
    local AmountLabel = NewLabel(Row, {
        Position = UDim2.new(1, -92, 0, 0), Size = UDim2.new(0, 26, 1, 0),
        Font = Enum.Font.GothamBold, Text = "×1", TextSize = 12,
        TextColor3 = Theme.Honey, TextXAlignment = Enum.TextXAlignment.Center,
    })
    local AmountMinus = StepButton(Row, "−", -118, 24)

    local Target = {
        Product = Product,
        Amount = Quantity,
        Row = Row,
        Dot = Dot,
        StateLabel = StateLabel,
        AmountLabel = AmountLabel,
        WatchSince = os.clock(),
        LastLive = nil,
    }

    local function SetAmount(Value)
        Target.Amount = math.clamp(Value, 1, 50)
        AmountLabel.Text = "×" .. Target.Amount
    end
    SetAmount(Quantity)

    AmountPlus.MouseButton1Click:Connect(function() SetAmount(Target.Amount + 1) end)
    AmountMinus.MouseButton1Click:Connect(function() SetAmount(Target.Amount - 1) end)
    Remove.MouseButton1Click:Connect(function() RemoveTarget(Product.Name) end)

    table.insert(Targets, Target)
    TargetByName[Product.Name] = Target
    RefreshTargetsHeader()
    if UpdateCardTargetVisual then UpdateCardTargetVisual(Product.Name) end
    Sniper.LastState = nil
end

local function ToggleTarget(Product)
    if TargetByName[Product.Name] then
        RemoveTarget(Product.Name)
        SetStatus(Product.Name .. " sacado del sniper", Theme.TextDim)
    else
        AddTarget(Product)
        SetStatus(Product.Name .. " agregado al sniper", Theme.Honey)
    end
end

local function PaintTargetState(Target, Live)
    if Target.LastLive == Live then return end
    Target.LastLive = Live

    if Live == true then
        Tween(Target.Dot, Quick, {BackgroundColor3 = Theme.Success})
        Target.StateLabel.Text = "stock disponible"
        Target.StateLabel.TextColor3 = Theme.Success
    elseif Live == false then
        Tween(Target.Dot, Quick, {BackgroundColor3 = Theme.Error})
        Target.StateLabel.Text = "sin stock — esperando restock"
        Target.StateLabel.TextColor3 = Theme.TextFaint
        Target.WatchSince = os.clock() -- arranca el reloj del restock
    else
        Tween(Target.Dot, Quick, {BackgroundColor3 = Theme.Warning})
        Target.StateLabel.Text = "tienda cerrada"
        Target.StateLabel.TextColor3 = Theme.Warning
    end
end

local function SniperStatus(State, Text, Color)
    -- evita repintar el mismo mensaje en cada vuelta del loop
    if Sniper.LastState == State then return end
    Sniper.LastState = State
    SetStatus(Text, Color)
end

local function SetSniperVisual()
    PaintSniper(Sniper.Enabled)
    SniperHint.Text = Sniper.Enabled
        and "vigilando — compra apenas haya stock"
        or "compra sola apenas haya stock"
    Tween(SniperDot, Quick, {BackgroundColor3 = Sniper.Enabled and Theme.Honey or Theme.TextFaint})
end

SniperRow.MouseButton1Click:Connect(function()
    Sniper.Enabled = not Sniper.Enabled
    Sniper.LastState = nil
    for _, Target in ipairs(Targets) do
        Target.LastLive = nil
        Target.WatchSince = os.clock()
    end
    SetSniperVisual()

    if not Sniper.Enabled then
        SetStatus("Sniper apagado", Theme.TextDim)
    elseif #Targets == 0 then
        SetStatus("Sniper armado — marcá objetivos con 🎯", Theme.Warning)
    else
        SetStatus(string.format("Sniper armado sobre %d objetivo(s)", #Targets), Theme.Honey)
    end
end)

-- Latido del punto del header mientras el sniper corre
task.spawn(function()
    while ScreenGui.Parent do
        if Sniper.Enabled then
            Tween(SniperDot, TweenInfo.new(0.45), {BackgroundTransparency = 0.7})
            task.wait(0.45)
            Tween(SniperDot, TweenInfo.new(0.45), {BackgroundTransparency = 0})
            task.wait(0.45)
        else
            SniperDot.BackgroundTransparency = 0
            task.wait(0.3)
        end
    end
end)

-- Bucle principal. Sin delay: un frame es lo mínimo que se puede esperar
-- sin colgar el cliente, y el chequeo de stock es O(etiquetas cacheadas)
-- por objetivo, así que correr por frame no cuesta nada.
task.spawn(function()
    while ScreenGui.Parent do
        if Sniper.Enabled and not Busy then
            if #Targets == 0 then
                SniperStatus("empty", "Sniper armado — marcá objetivos con 🎯", Theme.Warning)
            else
                local Waiting, ShopClosed = 0, false

                for _, Target in ipairs(Targets) do
                    if Busy then break end

                    local Live = CheckStock(Target.Product)
                    PaintTargetState(Target, Live)

                    if Live == nil then
                        ShopClosed = true
                        break
                    elseif Live == false then
                        Waiting = Waiting + 1
                    else
                        -- hay stock: comprar ya, sin esperar al próximo frame
                        Busy = true
                        Sniper.LastState = nil
                        BuyBtn.Text = "Sniping..."

                        local Waited = os.clock() - Target.WatchSince
                        local Bought = ExecutePurchase(Target.Product, Target.Amount, "sniper", Waited)
                        Target.WatchSince = os.clock()
                        Target.LastLive = nil

                        if Bought > 0 then
                            SetStatus(string.format("🎯 %s × %d  ·  esperó %s",
                                Target.Product.Name, Bought, ShortTime(Waited)), Theme.Success)
                        end

                        Busy = false
                        RefreshBuyLabel()
                    end
                end

                if ShopClosed then
                    SniperStatus("closed", "Sniper esperando — abrí la tienda", Theme.Warning)
                elseif Waiting == #Targets then
                    SniperStatus("watch", string.format("Sniper vigilando %d objetivo(s) — sin stock", Waiting), Theme.TextDim)
                end
            end
        end
        RunService.PostSimulation:Wait()
    end
end)

-- ═══════════════════════════ TARJETAS ═══════════════════════════

local function SelectProduct(Product, Card)
    if SelectedCard then
        Tween(SelectedCard, Quick, {BackgroundColor3 = Theme.Card})
        local OldStroke = CardStrokes[SelectedCard]
        if OldStroke then Tween(OldStroke, Quick, {Transparency = 1}) end
    end

    Selected, SelectedCard = Product, Card
    Tween(Card, Quick, {BackgroundColor3 = Theme.CardHover})
    local NewStroke = CardStrokes[Card]
    if NewStroke then Tween(NewStroke, Quick, {Transparency = 0}) end

    RefreshDetail()
    RefreshBuyLabel()
end

local function BuildCard(Product, Index)
    local Card = Instance.new("TextButton")
    Card.Size = UDim2.new(1, -6, 0, 56)
    Card.BackgroundColor3 = Theme.Card
    Card.AutoButtonColor = false
    Card.Text = ""
    Card.LayoutOrder = Index
    Card.Parent = List
    Corner(Card, 9)

    local SelectStroke = Stroke(Card, Theme.Honey, 1.5, 1)
    CardStrokes[Card] = SelectStroke

    local TierColor = TierColors[math.min(Index, #TierColors)]

    local Accent = Instance.new("Frame")
    Accent.Size = UDim2.new(0, 3, 0, 32)
    Accent.Position = UDim2.new(0, 9, 0.5, -16)
    Accent.BackgroundColor3 = TierColor
    Accent.BorderSizePixel = 0
    Accent.Parent = Card
    Corner(Accent, 2)

    NewLabel(Card, {
        Position = UDim2.new(0, 20, 0, 9), Size = UDim2.new(1, -160, 0, 18),
        Font = Enum.Font.GothamBold, Text = Product.Name, TextSize = 13,
        TextColor3 = Theme.Text, TextTruncate = Enum.TextTruncate.AtEnd,
    })

    local StockLabel = NewLabel(Card, {
        Position = UDim2.new(0, 20, 0, 29), Size = UDim2.new(1, -160, 0, 16),
        Text = string.format("tope %s", Comma(Product.Stock)), TextSize = 11,
    })

    local Pill = Instance.new("Frame")
    Pill.Size = UDim2.new(0, 74, 0, 24)
    Pill.Position = UDim2.new(1, -122, 0.5, -12)
    Pill.BackgroundColor3 = Theme.SurfaceAlt
    Pill.BorderSizePixel = 0
    Pill.Parent = Card
    Corner(Pill, 12)

    NewLabel(Pill, {
        Size = UDim2.new(1, 0, 1, 0), Font = Enum.Font.GothamBold,
        Text = string.format("%s 🍯", Comma(Product.Price)), TextSize = 12,
        TextColor3 = TierColor, TextXAlignment = Enum.TextXAlignment.Center,
    })

    -- Botón de objetivo del sniper
    local TargetBtn = Instance.new("TextButton")
    TargetBtn.Size = UDim2.new(0, 32, 0, 32)
    TargetBtn.Position = UDim2.new(1, -42, 0.5, -16)
    TargetBtn.BackgroundColor3 = Theme.SurfaceAlt
    TargetBtn.Font = Enum.Font.GothamBold
    TargetBtn.Text = "🎯"
    TargetBtn.TextSize = 14
    TargetBtn.TextTransparency = 0.55
    TargetBtn.AutoButtonColor = false
    TargetBtn.Parent = Card
    Corner(TargetBtn, 8)
    local TargetStroke = Stroke(TargetBtn, Theme.Honey, 1.5, 1)

    CardsByProduct[Product.Name] = {
        Card = Card, StockLabel = StockLabel,
        TargetBtn = TargetBtn, TargetStroke = TargetStroke,
    }

    TargetBtn.MouseButton1Click:Connect(function() ToggleTarget(Product) end)

    Card.MouseEnter:Connect(function()
        if SelectedCard ~= Card then Tween(Card, Quick, {BackgroundColor3 = Theme.CardHover}) end
    end)
    Card.MouseLeave:Connect(function()
        if SelectedCard ~= Card then Tween(Card, Quick, {BackgroundColor3 = Theme.Card}) end
    end)
    Card.MouseButton1Click:Connect(function() SelectProduct(Product, Card) end)

    return Card
end

UpdateCardTargetVisual = function(Name)
    local Refs = CardsByProduct[Name]
    if not Refs then return end
    local IsTarget = TargetByName[Name] ~= nil
    Tween(Refs.TargetBtn, Quick, {
        BackgroundColor3 = IsTarget and Theme.Honey or Theme.SurfaceAlt,
        TextTransparency = IsTarget and 0 or 0.55,
    })
    Tween(Refs.TargetStroke, Quick, {Transparency = IsTarget and 0 or 1})
end

-- ═══════════════════════════ REFRESCO EN VIVO ═══════════════════════════

-- Pinta el stock real en cada tarjeta y mantiene el detalle y el reloj
-- de sesión al día. 4 Hz alcanza: sólo lee etiquetas ya cacheadas.
local function StartLiveRefresh(Products)
    task.spawn(function()
        while ScreenGui.Parent do
            for _, Product in ipairs(Products) do
                local Refs = CardsByProduct[Product.Name]
                if Refs then
                    local Live = CheckStock(Product)
                    if Live == true then
                        Refs.StockLabel.Text = "EN STOCK"
                        Refs.StockLabel.TextColor3 = Theme.Success
                    elseif Live == false then
                        Refs.StockLabel.Text = "sin stock"
                        Refs.StockLabel.TextColor3 = Theme.Error
                    else
                        Refs.StockLabel.Text = string.format("tope %s", Comma(Product.Stock))
                        Refs.StockLabel.TextColor3 = Theme.TextDim
                    end
                end
            end
            if Selected and ActiveTab == "Tienda" then RefreshDetail() end
            if ActiveTab == "Stats" then RefreshStats() end
            task.wait(0.25)
        end
    end)
end

-- ═══════════════════════════ ARRANQUE ═══════════════════════════

SetQuantity(1)
SetSniperVisual()
PaintSound(Settings.Sound)
PaintToast(Settings.Toasts)
RefreshTargetsHeader()
RefreshStats()
ShowTab("Tienda")
TabIndicator.Position = UDim2.new(0, 12, 1, -2)
TabIndicator.Size = UDim2.new(1 / TAB_COUNT, -24, 0, 2)

for _, Entry in ipairs(History) do RenderLogEntry(Entry) end

Root.Size = UDim2.new(0, WIDTH, 0, 0)
Tween(Root, Smooth, {Size = UDim2.new(0, WIDTH, 0, HEIGHT)})

local Products, Err = GetProducts()

if not Products then
    Subtitle.Text = "error"
    SetStatus(tostring(Err), Theme.Error)
    Notify("Honey Merchant", tostring(Err), "error")
else
    for Index, Product in ipairs(Products) do
        BuildCard(Product, Index)
    end
    Subtitle.Text = string.format("BeeMerchant · %d items", #Products)
    SetStatus("Elegí un producto — marcá 🎯 para el sniper", Theme.TextDim)
    StartLiveRefresh(Products)
end
