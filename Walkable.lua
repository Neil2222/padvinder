-- Where you can probably walk, also where you have never been: QuestieDB knows where every NPC and
-- mob spawns, and the patrol paths some of them walk. Creatures stand on ground you can reach, and
-- a patrol path is walkable by definition (often a road). Bare mountain ridges have none of them.
--
-- All spawns are put in a grid of WALK_CELL-yard squares (one node per square that has any,
-- at their average position); patrol paths join the squares they pass through. The route planner
-- uses this as a second, less trusted layer next to the paths you recorded yourself.
--
-- Built once per session in the background (a few milliseconds per frame), WAIT seconds after
-- logging in so it doesn't overlap with the other startup work.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local WALK_CELL = 32   -- yards
local WAIT = 10        -- seconds after login
ns.WALK_CELL = WALK_CELL

-- ns.walk[inst] = {n, X[], Y[], N[] (spawns), CX[], CY[], grid[key] = i, patrol = {a1, b1, a2, b2, ...}}
ns.walk = nil
ns.walkReady = false

local floor = math.floor

function ns.WalkKey(cx, cy)
    return (cx + 5000) * 10000 + (cy + 5000)
end
local WalkKey = ns.WalkKey

local function AreaToUiMap(Q)
    local ok, zone = pcall(Q.Support.Get, "ZoneDB")
    local z = ok and type(zone) == "table" and zone.private and zone.private.areaIdToUiMapId
    if type(z) == "string" then
        local f = loadstring(z)
        z = f and f()
    end
    return type(z) == "table" and z or nil
end

local function Build()
    local Q = LibQuestieDB
    local areaMap = Q and Q.Npc and Q.Npc.GetAllIds and Q.Support and AreaToUiMap(Q)
    if not areaMap then return end

    local walk = {}
    local function Add(inst, x, y)
        local w = walk[inst]
        if not w then
            w = {n = 0, X = {}, Y = {}, N = {}, CX = {}, CY = {}, grid = {}, patrol = {}}
            walk[inst] = w
        end
        local cx, cy = floor(x / WALK_CELL), floor(y / WALK_CELL)
        local key = WalkKey(cx, cy)
        local i = w.grid[key]
        if not i then
            i = w.n + 1
            w.n = i
            w.grid[key] = i
            w.X[i], w.Y[i], w.N[i], w.CX[i], w.CY[i] = x, y, 1, cx, cy
        else
            local n = w.N[i] + 1
            w.N[i] = n
            w.X[i] = w.X[i] + (x - w.X[i]) / n
            w.Y[i] = w.Y[i] + (y - w.Y[i]) / n
        end
        return i, w
    end
    local function World(area, x, y)
        local m = areaMap[area]
        if not m or not x or not y or x < 0 or y < 0 then return nil end
        return HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, m)
    end

    local Npc = Q.Npc
    local ok, ids = pcall(Npc.GetAllIds)
    if not ok or type(ids) ~= "table" then return end
    for k, id in ipairs(ids) do
        local okS, spawns = pcall(Npc.spawns, id)
        if okS and type(spawns) == "table" then
            for area, list in pairs(spawns) do
                for _, p in ipairs(list) do
                    local x, y, inst = World(area, p[1], p[2])
                    if x then Add(inst, x, y) end
                end
            end
        end
        local okW, ways = pcall(Npc.waypoints, id)
        if okW and type(ways) == "table" then
            for area, paths in pairs(ways) do
                for _, path in ipairs(paths) do
                    local prev, prevW
                    for _, p in ipairs(path) do
                        local x, y, inst = World(area, p[1], p[2])
                        if x then
                            local i, w = Add(inst, x, y)
                            if prev and prevW == w and prev ~= i then
                                local pt = w.patrol
                                pt[#pt + 1], pt[#pt + 1] = prev, i
                            end
                            prev, prevW = i, w
                        else
                            prev = nil
                        end
                    end
                end
            end
        end
        if k % 40 == 0 then ns.MaybeYield() end
    end
    ns.walk = walk
    ns.walkRev = (ns.walkRev or 0) + 1
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    local wait, job = 0, nil
    frame:SetScript("OnUpdate", function(_, elapsed)
        if not job then
            wait = wait + elapsed
            if wait < WAIT then return end
            job = coroutine.create(Build)
        end
        ns.SliceStart()
        local ok, err = coroutine.resume(job)
        if not ok or coroutine.status(job) == "dead" then
            if not ok then ns.Print("reading QuestieDB failed: " .. tostring(err)) end
            ns.walkReady = true
            frame:SetScript("OnUpdate", nil)
        end
    end)
end)
