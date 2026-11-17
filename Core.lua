-- Padvinder: records the paths you walk as a grid of cells with connections between them.
--
-- Data model (PadvinderDB, account-wide):
--   worlds[instanceID] = {
--     cells = { ["cx:cy"] = times entered },
--     edges = { ["cx:cy>cx:cy"] = times walked in that direction },
--     drops = { [edgeKey] = true }        -- only ever fallen down, can't be walked back
--     swim  = { [cellKey] = true }        -- cell where you swam
--     fight = { [edgeKey] = count }       -- part of edges[...] walked in/just after combat
--     fightCells = { [cellKey] = count }  -- same for cells
--   }
-- Coordinates are world coordinates in yards (HereBeDragons), so paths continue
-- across zone borders.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local CELL = 8            -- cell size in yards; also the minimum step between samples
local MAX_STEP = 40       -- a bigger jump = teleport, hearth, res: no connection
local FALL_ONEWAY = 0.9   -- this many seconds falling between two samples = one-way connection
local TICK = 0.1
local COMBAT_LINGER = 8   -- for this many seconds after combat, walking still counts as grinding (looting, next mob)

ns.CELL = CELL
ns.rev = 0                -- bumped on every data change, so the map knows to redraw

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

-- Center of a cell in world coordinates (cached, the map asks for this a lot).
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

-- Recording state
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
            w.drops[ek] = nil   -- walked normally at least once: it's passable
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

-- Stats
local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function Info()
    ns.Print("recording: " .. (PadvinderDB.recording and "|cff00ff00on|r" or "|cffff4444off|r")
        .. ", map: " .. (PadvinderDB.showMap and PadvinderDB.mapMode or "off"))
    local any = false
    for inst in pairs(PadvinderDB.worlds) do
        local w = World(inst)
        any = true
        local travel, grinding = 0, 0
        for ek, n in pairs(w.edges) do
            local a, b = ek:match("^(.-)>(.+)$")
            local ax, ay = ns.CellCenter(a)
            local bx, by = ns.CellCenter(b)
            local len = sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
            if n - (w.fight[ek] or 0) > 0 then travel = travel + len else grinding = grinding + len end
        end
        ns.Print(("world %s: %d cells, %d connections, ~%.1f km travel, ~%.1f km grinding")
            :format(tostring(inst), Count(w.cells), Count(w.edges),
                travel * 0.9144 / 1000, grinding * 0.9144 / 1000))
    end
    if not any then ns.Print("nothing recorded yet. Go for a run!") end
end

local function Help()
    ns.Print("commands:")
    print("  /pad info  - what has been recorded")
    print("  /pad on | off  - recording on/off")
    print("  /pad map  - show/hide paths on the world map")
    print("  /pad show all | travel | grind  - which paths to show on the map")
    print("  /pad wipe confirm  - erase EVERYTHING")
end

local MODE_ALIASES = {
    all = "all", travel = "travel", grind = "grind", grinding = "grind", combat = "grind",
}

SLASH_PADVINDER1 = "/pad"
SLASH_PADVINDER2 = "/padvinder"
SlashCmdList.PADVINDER = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "on" then
        PadvinderDB.recording = true
        ns.Print("recording is |cff00ff00on|r.")
    elseif msg == "off" then
        PadvinderDB.recording = false
        ns.Print("recording is |cffff4444off|r.")
    elseif msg == "map" then
        PadvinderDB.showMap = not PadvinderDB.showMap
        ns.rev = ns.rev + 1
        ns.Print("paths on the map: " .. (PadvinderDB.showMap and "on" or "off") .. ".")
    elseif msg:match("^show") then
        local mode = MODE_ALIASES[msg:match("^show%s+(%S+)") or ""]
        if mode then
            PadvinderDB.mapMode = mode
            PadvinderDB.showMap = true
            ns.rev = ns.rev + 1
            ns.Print("map now shows: " .. mode .. ".")
        else
            ns.Print("usage: /pad show all | travel | grind")
        end
    elseif msg == "info" then
        Info()
    elseif msg == "wipe confirm" then
        PadvinderDB.worlds = {}
        Break()
        ns.rev = ns.rev + 1
        ns.Print("everything erased.")
    elseif msg == "wipe" then
        ns.Print("are you sure? Type |cffffff00/pad wipe confirm|r to erase everything.")
    else
        Help()
    end
end

-- Startup
local OLD_MODES = {alles = "all", reizen = "travel", grinden = "grind", gevecht = "grind"}

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
        db.mapMode = OLD_MODES[db.mapMode] or db.mapMode or "all"
        db.worlds = db.worlds or {}
        for inst in pairs(db.worlds) do World(inst) end   -- fill in newer tables for older data
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
        ns.Print("loaded. Recording is " .. (PadvinderDB.recording and "on" or "off") .. ". Type /pad for help.")
    elseif event == "PLAYER_ENTERING_WORLD" then
        Break()
    end
end)
