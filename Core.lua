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
--     ax, ay = { [cellKey] = yards }      -- average position actually walked in the cell
--   }
-- Coordinates are world coordinates in yards (HereBeDragons), so paths continue
-- across zone borders.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local CELL = 8            -- cell size in yards; also the minimum step between samples
local MAX_STEP = 40       -- a bigger jump = teleport, hearth, res: no connection
local FALL_ONEWAY = 0.9   -- this many seconds falling between two samples = one-way connection
local TICK = 0.1
local COMBAT_LINGER = 30  -- for this many seconds after combat, walking still counts as grinding (looting, next mob)
local COMBAT_LEADIN = 15  -- when combat starts, the last this-many seconds of walking count as grinding too (walking up to the mob)
local TRANSPORT_MARGIN = 3  -- yards/s: moving this much faster than your own speed = standing on a boat/zeppelin
local TRANSPORT_HOLD = 3    -- seconds: still counts as on a transport after the last sign of it

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
    w.ax = w.ax or {}
    w.ay = w.ay or {}
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

-- Count a visit to a cell and fold the real position into its running average, so lines
-- follow where you actually walked instead of a staircase of cell centres.
local function Visit(w, key, x, y)
    local n = (w.cells[key] or 0) + 1
    w.cells[key] = n
    local ax = w.ax[key]
    if ax then
        local ay = w.ay[key]
        w.ax[key] = floor((ax + (x - ax) / n) * 10 + 0.5) / 10
        w.ay[key] = floor((ay + (y - ay) / n) * 10 + 0.5) / 10
    else
        w.ax[key] = floor(x * 10 + 0.5) / 10
        w.ay[key] = floor(y * 10 + 0.5) / 10
    end
end

-- Where to draw a cell: its average walked position, or its centre for data from before 0.3.
function ns.CellPos(w, key)
    local ax = w.ax[key]
    if ax then return ax, w.ay[key] end
    return ns.CellCenter(key)
end

-- Recording state
local lastX, lastY, lastInst, lastKey
local fallTime = 0
local lastCombat = -1000
local fightInStep = false
local wasInCombat = false
local recent = {}   -- recent travel steps {t, inst, ek, key}, retagged as grinding when combat starts
local tickX, tickY, tickInst
local lastTransport = -1000

-- Standing on a boat or zeppelin: the position moves faster than you do yourself (there is no
-- API for "on a transport"). ns.onTransport is also used by the route planner.
local function DetectTransport(x, y, inst, elapsed, now)
    if tickX and inst == tickInst and elapsed > 0 and GetUnitSpeed then
        local dx, dy = x - tickX, y - tickY
        local v = sqrt(dx * dx + dy * dy) / elapsed
        local own = GetUnitSpeed("player") or 0
        if v > own + TRANSPORT_MARGIN and v < 200 then lastTransport = now end   -- (200+: teleport)
    end
    tickX, tickY, tickInst = x, y, inst
    ns.onTransport = now - lastTransport < TRANSPORT_HOLD
end

local function TagFight(w, ek, key)
    w.fight[ek] = (w.fight[ek] or 0) + 1
    w.fightCells[key] = (w.fightCells[key] or 0) + 1
end

-- Combat just started: the walk leading up to it was grinding, not travel.
local function RetagLeadIn(now)
    for _, step in ipairs(recent) do
        if now - step.t <= COMBAT_LEADIN then
            local w = PadvinderDB.worlds[step.inst]
            if w and (w.edges[step.ek] or 0) > (w.fight[step.ek] or 0) then
                TagFight(w, step.ek, step.key)
            end
        end
    end
    wipe(recent)
    ns.rev = ns.rev + 1
end

local function Break()
    lastX, lastY, lastInst, lastKey = nil, nil, nil, nil
    fallTime = 0
    fightInStep = false
end

local function Start(x, y, inst)
    lastX, lastY, lastInst = x, y, inst
    lastKey = CellKey(x, y)
    local w = World(inst)
    Visit(w, lastKey, x, y)
    fallTime = 0
    ns.rev = ns.rev + 1
end

local function Tick(elapsed)
    local x, y, inst = HBD:GetPlayerWorldPosition()
    if not x or not y or not inst or (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then
        tickX = nil
        Break()
        return
    end
    local now = GetTime()
    DetectTransport(x, y, inst, elapsed, now)

    if not PadvinderDB.recording then Break() return end
    if UnitOnTaxi("player") or IsInInstance() or ns.onTransport then Break() return end

    if IsFalling() then fallTime = fallTime + elapsed end
    local inCombat = UnitAffectingCombat("player")
    if inCombat then
        lastCombat = now
        if not wasInCombat then RetagLeadIn(now) end
    end
    wasInCombat = inCombat
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
        Visit(w, key, x, y)
        local ek = lastKey .. ">" .. key
        w.edges[ek] = (w.edges[ek] or 0) + 1
        if fallTime >= FALL_ONEWAY then
            w.drops[ek] = true
        else
            w.drops[ek] = nil   -- walked normally at least once: it's passable
        end
        if IsSwimming() then w.swim[key] = true end
        if fightInStep then
            TagFight(w, ek, key)
        else
            recent[#recent + 1] = {t = now, inst = inst, ek = ek, key = key}
            while recent[1] and now - recent[1].t > COMBAT_LEADIN do table.remove(recent, 1) end
        end
        if ns.OnNewEdge then ns.OnNewEdge(inst, w, ek, lastKey, key) end
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

-- Returns cells, connections, km travel, km grinding for one world.
function ns.Stats(inst)
    local w = PadvinderDB.worlds[inst]
    if not w then return 0, 0, 0, 0 end
    w = World(inst)
    local travel, grinding = 0, 0
    for ek, n in pairs(w.edges) do
        local a, b = ek:match("^(.-)>(.+)$")
        local ax, ay = ns.CellCenter(a)
        local bx, by = ns.CellCenter(b)
        local len = sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
        if n - (w.fight[ek] or 0) > 0 then travel = travel + len else grinding = grinding + len end
    end
    return Count(w.cells), Count(w.edges), travel * 0.9144 / 1000, grinding * 0.9144 / 1000
end

local function Info()
    ns.Print("recording: " .. (PadvinderDB.recording and "|cff00ff00on|r" or "|cffff4444off|r")
        .. ", map: " .. (PadvinderDB.showMap and PadvinderDB.mapMode or "off")
        .. ", minimap: " .. (PadvinderDB.showMinimap and "on" or "off"))
    local any = false
    for inst in pairs(PadvinderDB.worlds) do
        any = true
        local cells, conns, travel, grinding = ns.Stats(inst)
        ns.Print(("world %s: %d cells, %d connections, ~%.1f km travel, ~%.1f km grinding")
            :format(tostring(inst), cells, conns, travel, grinding))
    end
    if not any then ns.Print("nothing recorded yet. Go for a run!") end
    if ns.lastLineCount then ns.Print("lines on the map last time it was drawn: " .. ns.lastLineCount) end
    if ns.RouteInfo then ns.Print("route: " .. ns.RouteInfo()) end
    if ns.lastMinimapLineCount then ns.Print("lines on the minimap right now: " .. ns.lastMinimapLineCount) end
end

function ns.SetRecording(on)
    PadvinderDB.recording = on
    ns.Print("recording is " .. (on and "|cff00ff00on|r" or "|cffff4444off|r") .. ".")
    if ns.UpdateButton then ns.UpdateButton() end
end

function ns.SetMinimap(show)
    PadvinderDB.showMinimap = show
    if ns.RefreshMinimap then ns.RefreshMinimap() end
    ns.Print("minimap paths: " .. (show and "on" or "off") .. ".")
end

function ns.SetMap(show, mode)
    PadvinderDB.showMap = show
    if mode then PadvinderDB.mapMode = mode end
    ns.rev = ns.rev + 1
    ns.Print("map: " .. (show and PadvinderDB.mapMode or "off") .. ".")
    if ns.UpdateButton then ns.UpdateButton() end
end

local function Help()
    ns.Print("commands:")
    print("  /pad info  - what has been recorded")
    print("  /pad on | off | toggle  - recording on/off (toggle is handy for a macro)")
    print("  /pad map  - show/hide paths on the world map")
    print("  /pad minimap  - show/hide paths on the minimap")
    print("  /pad show all | travel | grind  - which paths to show (map and minimap)")
    print("  /pad route  - route planner on/off (follows your TomTom/Questie waypoint)")
    print("  /pad button  - show/hide the minimap button")
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
        ns.SetRecording(true)
    elseif msg == "off" then
        ns.SetRecording(false)
    elseif msg == "toggle" then
        ns.SetRecording(not PadvinderDB.recording)
    elseif msg == "map" then
        ns.SetMap(not PadvinderDB.showMap)
    elseif msg == "minimap" then
        ns.SetMinimap(not PadvinderDB.showMinimap)
    elseif msg == "route" then
        if ns.SetRouting then ns.SetRouting(not PadvinderDB.routing) end
    elseif msg == "button" then
        if ns.ToggleButton then ns.ToggleButton() end
    elseif msg:match("^show") then
        local mode = MODE_ALIASES[msg:match("^show%s+(%S+)") or ""]
        if mode then
            ns.SetMap(true, mode)
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
        if db.showMinimap == nil then db.showMinimap = true end
        if db.routing == nil then db.routing = true end
        db.mapMode = OLD_MODES[db.mapMode] or db.mapMode or "all"
        db.minimap = db.minimap or {}
        db.worlds = db.worlds or {}
        for inst in pairs(db.worlds) do World(inst) end   -- fill in newer tables for older data
    elseif event == "PLAYER_LOGIN" then
        if ns.InitMap then ns.InitMap() end
        if ns.InitMinimap then ns.InitMinimap() end
        if ns.InitButton then ns.InitButton() end
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
