-- Flight paths, boats and zeppelins for the route planner.
--
--  * Which flight points this character has found: the flight map tells (when you open a flight
--    master: CURRENT and REACHABLE are found, anything else is not), and "New flight path
--    discovered!" adds the nearest one. On first use the list ForeverDungeonJournal keeps (if it
--    is installed) is taken over, so you don't have to visit every flight master again.
--  * Where flight points are: the game's own list (C_TaxiMap.GetTaxiNodesForMap), per zone.
--  * How long a flight takes: learned on every flight (PadvinderDB.flightTimes, seconds).
--  * Boats, zeppelins, portals: ns.RIDES (Data.lua).
--
-- ns.transportRev bumps whenever any of this changes, so the route planner rebuilds its graph.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local CONTINENT_MAPS = {1415, 1414, 2665}   -- Eastern Kingdoms, Kalimdor, the Skyborne's isles
local FOUND_NEAR = 100                       -- yards: "New flight path discovered!" within this

ns.transportRev = 0

local function Bump() ns.transportRev = ns.transportRev + 1 end

local function Found()
    PadvinderCharDB = PadvinderCharDB or {}
    PadvinderCharDB.flights = PadvinderCharDB.flights or {}
    return PadvinderCharDB.flights
end

local function Faction()
    return UnitFactionGroup and UnitFactionGroup("player") or nil
end

local function OurSide(nodeFaction)
    if nodeFaction == 1 then return Faction() == "Horde" end
    if nodeFaction == 2 then return Faction() == "Alliance" end
    return true
end

---------------------------------------------------------------------------------------------
-- Flight points

local nodesCache, nodesRev

-- All flight points the game knows on our side: {id, name, short, inst, x, y} (world yards).
local function AllNodes()
    if nodesCache and nodesRev == ns.transportRev then return nodesCache end
    local list, seen = {}, {}
    if C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap and C_Map and C_Map.GetMapChildrenInfo then
        local function Add(mapID)
            local ok, nodes = pcall(C_TaxiMap.GetTaxiNodesForMap, mapID)
            if not ok or type(nodes) ~= "table" then return end
            for _, node in ipairs(nodes) do
                local id = type(node) == "table" and node.nodeID
                if id and not seen[id] and type(node.name) == "string" and type(node.position) == "table"
                    and OurSide(node.faction) then
                    local nx, ny = node.position.x, node.position.y
                    if (not nx or not ny) and node.position.GetXY then nx, ny = node.position:GetXY() end
                    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(nx, ny, mapID)
                    if wx then
                        seen[id] = true
                        list[#list + 1] = {id = id, name = node.name, short = node.name:match("^%s*(.-)%s*,") or node.name,
                            inst = inst, x = wx, y = wy}
                    end
                end
            end
        end
        for _, continent in ipairs(CONTINENT_MAPS) do
            local ok, zones = pcall(C_Map.GetMapChildrenInfo, continent, 3, true)   -- 3 = Enum.UIMapType.Zone
            if ok and type(zones) == "table" then
                for _, zone in ipairs(zones) do
                    if type(zone) == "table" and zone.mapID then Add(zone.mapID) end
                end
            end
        end
    end
    nodesCache, nodesRev = list, ns.transportRev
    return list
end

-- The flight points this character can use.
function ns.FlightNodes()
    local found, out = Found(), {}
    for _, node in ipairs(AllNodes()) do
        if found[node.name:lower()] then out[#out + 1] = node end
    end
    return out
end

-- The flight map is open: it is the last word on which flight points are found.
local function RecordFlightMap()
    if not (NumTaxiNodes and TaxiNodeName and TaxiNodeGetType) then return end
    local found, changed = Found(), false
    for i = 1, NumTaxiNodes() or 0 do
        local name, kind = TaxiNodeName(i), TaxiNodeGetType(i)
        if type(name) == "string" and name ~= "" and type(kind) == "string"
            and not (issecretvalue and (issecretvalue(name) or issecretvalue(kind))) then
            local key = name:lower()
            local isFound = kind == "CURRENT" or kind == "REACHABLE"
            if isFound and not found[key] then
                found[key], changed = true, true
            elseif not isFound and found[key] then
                found[key], changed = nil, true
            end
        end
    end
    if changed then Bump() end
end

-- "New flight path discovered!": the nearest flight point is found.
local function FoundHere()
    local x, y, inst = HBD:GetPlayerWorldPosition()
    if not x then return end
    local best, bestD
    for _, node in ipairs(AllNodes()) do
        if node.inst == inst then
            local d = math.sqrt((node.x - x) ^ 2 + (node.y - y) ^ 2)
            if d <= FOUND_NEAR and (not bestD or d < bestD) then best, bestD = node, d end
        end
    end
    if best then
        Found()[best.name:lower()] = true
        Bump()
    end
end

-- Take over the flight points ForeverDungeonJournal knows (same names, lower case).
local function ImportFDJ()
    local fdj = ForeverDungeonJournalCharacterDB
    if type(fdj) ~= "table" or type(fdj.flightPoints) ~= "table" then return end
    local found, n = Found(), 0
    for key, v in pairs(fdj.flightPoints) do
        if v == true and type(key) == "string" and not found[key] then
            found[key] = true
            n = n + 1
        end
    end
    if n > 0 then Bump() end
end

---------------------------------------------------------------------------------------------
-- Flight times: from picking a destination until landing.

local flight   -- {from, to, up = takeoff time}
local function CurrentName()
    if not (NumTaxiNodes and TaxiNodeGetType and TaxiNodeName) then return nil end
    for i = 1, NumTaxiNodes() or 0 do
        if TaxiNodeGetType(i) == "CURRENT" then return TaxiNodeName(i) end
    end
end

-- Seconds a flight from one found flight point to another took last time (names), or nil.
function ns.FlightTime(fromName, toName)
    local t = PadvinderDB.flightTimes
    return t and t[fromName:lower() .. ">" .. toName:lower()]
end

local wasOnTaxi = false
local function WatchTaxi()
    local on = UnitOnTaxi("player")
    if on and not wasOnTaxi and flight then
        flight.up = GetTime()
    elseif not on and wasOnTaxi then
        if flight and flight.up then
            local seconds = GetTime() - flight.up
            if seconds > 5 then
                PadvinderDB.flightTimes = PadvinderDB.flightTimes or {}
                PadvinderDB.flightTimes[flight.from:lower() .. ">" .. flight.to:lower()] = math.floor(seconds + 0.5)
                Bump()
            end
        end
        flight = nil
        if ns.OnLanded then ns.OnLanded() end
    end
    wasOnTaxi = on
end

---------------------------------------------------------------------------------------------
-- Boats, zeppelins, portals: both ends in world yards, only the ones for our faction.

local ridesCache
function ns.Rides()
    if ridesCache then return ridesCache end
    local out = {}
    for _, r in ipairs(ns.RIDES or {}) do
        if not r.faction or r.faction == Faction() then
            local fx, fy, fi = HBD:GetWorldCoordinatesFromZone(r.from[2], r.from[3], r.from[1])
            local tx, ty, ti = HBD:GetWorldCoordinatesFromZone(r.to[2], r.to[3], r.to[1])
            if fx and tx then
                out[#out + 1] = {kind = r.kind, fromName = r.fromName, toName = r.toName,
                    fx = fx, fy = fy, finst = fi, tx = tx, ty = ty, tinst = ti}
            end
        end
    end
    ridesCache = out
    return out
end

---------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("TAXIMAP_OPENED")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        Found()
        ImportFDJ()
        if hooksecurefunc then
            hooksecurefunc("TakeTaxiNode", function(slot)
                local from, to = CurrentName(), TaxiNodeName(slot)
                if from and to then flight = {from = from, to = to} end
            end)
        end
        local acc = 0
        frame:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + elapsed
            if acc >= 0.25 then
                acc = 0
                WatchTaxi()
            end
        end)
    elseif event == "TAXIMAP_OPENED" then
        RecordFlightMap()
    elseif event == "UI_INFO_MESSAGE" then
        for i = 1, select("#", ...) do
            if select(i, ...) == ERR_NEWTAXIPATH then FoundHere() break end
        end
    end
end)
