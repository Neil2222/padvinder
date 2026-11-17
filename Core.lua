-- Padvinder: neemt gelopen paden op als een raster van cellen met verbindingen ertussen.
--
-- Datamodel (PadvinderDB, account-breed):
--   worlds[instanceID] = {
--     cells = { ["cx:cy"] = aantal keer betreden },
--     edges = { ["cx:cy>cx:cy"] = aantal keer gelopen in die richting },
--     drops = { [edgeKey] = true }   -- alleen gevallen, niet terug te lopen
--     swim  = { [cellKey] = true }   -- cel waar gezwommen is
--     fight = { [edgeKey] = aantal } -- deel van edges[...] dat in/vlak na gevecht gelopen is
--     fightCells = { [cellKey] = aantal } -- idem voor cells
--   }
-- Coördinaten zijn wereldcoördinaten in yards (HereBeDragons), zodat paden
-- doorlopen over zonegrenzen heen.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local CELL = 8            -- celgrootte in yards; ook de minimale stap tussen samples
local MAX_STEP = 40       -- grotere sprong = teleport, hearth, res: geen verbinding
local FALL_ONEWAY = 0.9   -- zoveel seconden vallen tussen twee samples = eenrichtingsverbinding
local TICK = 0.1
local COMBAT_LINGER = 8   -- zoveel seconden na een gevecht telt lopen nog als grinden (looten, volgende mob)

ns.CELL = CELL
ns.rev = 0                -- verhoogt bij elke nieuwe data, zodat de kaart weet dat hij moet hertekenen

local floor, sqrt = math.floor, math.sqrt

local PREFIX = "|cff66ccffPadvinder|r: "
function ns.Print(msg) print(PREFIX .. msg) end

local function World(inst)
    local w = PadvinderDB.worlds[inst]
    if not w then
        w = {}
        PadvinderDB.worlds[inst] = w
    end
    w.cells = w.cells or {}
    w.edges = w.edges or {}
    w.drops = w.drops or {}
    w.swim = w.swim or {}
    w.fight = w.fight or {}
    w.fightCells = w.fightCells or {}
    return w
end
ns.World = World

local function CellKey(x, y)
    return floor(x / CELL) .. ":" .. floor(y / CELL)
end

-- Middelpunt van een cel in wereldcoördinaten (gecachet, want de kaart vraagt dit vaak).
local centers = {}
function ns.CellCenter(key)
    local c = centers[key]
    if not c then
        local cx, cy = key:match("^(-?%d+):(-?%d+)$")
        c = {(tonumber(cx) + 0.5) * CELL, (tonumber(cy) + 0.5) * CELL}
        centers[key] = c
    end
    return c[1], c[2]
end

-- Opname-toestand
local lastX, lastY, lastInst, lastKey
local fallTime = 0
local lastCombat = -1000
local fightInStep = false

local function Break()
    lastX, lastY, lastInst, lastKey = nil, nil, nil, nil
    fallTime = 0
    fightInStep = false
end

local function Start(x, y, inst)
    lastX, lastY, lastInst = x, y, inst
    lastKey = CellKey(x, y)
    local w = World(inst)
    w.cells[lastKey] = (w.cells[lastKey] or 0) + 1
    fallTime = 0
    ns.rev = ns.rev + 1
end

local function Tick(elapsed)
    if not PadvinderDB.recording then Break() return end
    if UnitOnTaxi("player") or IsInInstance() then Break() return end

    local x, y, inst = HBD:GetPlayerWorldPosition()
    if not x or not y or not inst then Break() return end
    if issecretvalue and (issecretvalue(x) or issecretvalue(y)) then Break() return end

    if IsFalling() then fallTime = fallTime + elapsed end
    local now = GetTime()
    if UnitAffectingCombat("player") then lastCombat = now end
    if now - lastCombat < COMBAT_LINGER then fightInStep = true end

    if not lastX or inst ~= lastInst then
        Start(x, y, inst)
        return
    end

    local dx, dy = x - lastX, y - lastY
    local d = sqrt(dx * dx + dy * dy)
    if d > MAX_STEP then
        Start(x, y, inst)
        return
    end
    if d < CELL then return end

    local key = CellKey(x, y)
    if key ~= lastKey then
        local w = World(inst)
        w.cells[key] = (w.cells[key] or 0) + 1
        local ek = lastKey .. ">" .. key
        w.edges[ek] = (w.edges[ek] or 0) + 1
        if fallTime >= FALL_ONEWAY then
            w.drops[ek] = true
        else
            w.drops[ek] = nil   -- ooit normaal gelopen: dan is hij gewoon begaanbaar
        end
        if IsSwimming() then w.swim[key] = true end
        if fightInStep then
            w.fight[ek] = (w.fight[ek] or 0) + 1
            w.fightCells[key] = (w.fightCells[key] or 0) + 1
        end
        lastKey = key
        ns.rev = ns.rev + 1
    end
    lastX, lastY = x, y
    fallTime = 0
    fightInStep = false
end

-- Statistieken
local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function Info()
    ns.Print("opnemen: " .. (PadvinderDB.recording and "|cff00ff00aan|r" or "|cffff4444uit|r")
        .. ", kaart: " .. (PadvinderDB.showMap and PadvinderDB.mapMode or "uit"))
    local any = false
    for inst in pairs(PadvinderDB.worlds) do
        local w = World(inst)
        any = true
        local travel, fighting = 0, 0
        for ek, n in pairs(w.edges) do
            local a, b = ek:match("^(.-)>(.+)$")
            local ax, ay = ns.CellCenter(a)
            local bx, by = ns.CellCenter(b)
            local len = sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
            if n - (w.fight[ek] or 0) > 0 then travel = travel + len else fighting = fighting + len end
        end
        ns.Print(("wereld %s: %d cellen, %d verbindingen, ~%.1f km reizen, ~%.1f km grinden")
            :format(tostring(inst), Count(w.cells), Count(w.edges),
                travel * 0.9144 / 1000, fighting * 0.9144 / 1000))
    end
    if not any then ns.Print("nog niets opgenomen. Ga lekker rennen!") end
end

local function Help()
    ns.Print("commando's:")
    print("  /pad info  - wat is er opgenomen")
    print("  /pad aan | uit  - opnemen aan/uit")
    print("  /pad kaart  - paden op de wereldkaart tonen/verbergen")
    print("  /pad toon alles | reizen | grinden  - welke paden op de kaart")
    print("  /pad wis zeker  - ALLES wissen")
end

SLASH_PADVINDER1 = "/pad"
SLASH_PADVINDER2 = "/padvinder"
SlashCmdList.PADVINDER = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "aan" then
        PadvinderDB.recording = true
        ns.Print("opnemen staat |cff00ff00aan|r.")
    elseif msg == "uit" then
        PadvinderDB.recording = false
        ns.Print("opnemen staat |cffff4444uit|r.")
    elseif msg == "kaart" then
        PadvinderDB.showMap = not PadvinderDB.showMap
        ns.rev = ns.rev + 1
        ns.Print("paden op de kaart: " .. (PadvinderDB.showMap and "aan" or "uit") .. ".")
    elseif msg:match("^toon") then
        local mode = msg:match("^toon%s+(%S+)")
        if mode == "gevecht" or mode == "farmen" then mode = "grinden" end
        if mode == "alles" or mode == "reizen" or mode == "grinden" then
            PadvinderDB.mapMode = mode
            PadvinderDB.showMap = true
            ns.rev = ns.rev + 1
            ns.Print("kaart toont nu: " .. mode .. ".")
        else
            ns.Print("gebruik: /pad toon alles | reizen | grinden")
        end
    elseif msg == "info" then
        Info()
    elseif msg == "wis zeker" then
        PadvinderDB.worlds = {}
        Break()
        ns.rev = ns.rev + 1
        ns.Print("alles gewist.")
    elseif msg == "wis" then
        ns.Print("weet je het zeker? Typ |cffffff00/pad wis zeker|r om alles te wissen.")
    else
        Help()
    end
end

-- Opstarten
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        PadvinderDB = PadvinderDB or {}
        local db = PadvinderDB
        db.version = db.version or 1
        if db.recording == nil then db.recording = true end
        if db.showMap == nil then db.showMap = true end
        db.mapMode = db.mapMode or "alles"
        db.worlds = db.worlds or {}
        for inst in pairs(db.worlds) do World(inst) end   -- oudere data aanvullen met nieuwe tabellen
    elseif event == "PLAYER_LOGIN" then
        if ns.InitMap then ns.InitMap() end
        local acc = 0
        frame:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + elapsed
            if acc >= TICK then
                Tick(acc)
                acc = 0
            end
        end)
        ns.Print("geladen. Opnemen staat " .. (PadvinderDB.recording and "aan" or "uit") .. ". Typ /pad voor hulp.")
    elseif event == "PLAYER_ENTERING_WORLD" then
        Break()
    end
end)
