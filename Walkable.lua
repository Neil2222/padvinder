-- Where you can probably walk, also where you have never been: QuestieDB knows where every NPC and
-- mob spawns, and the patrol paths some of them walk. Creatures stand on ground you can reach, and
-- a patrol path is walkable by definition (often a road). Bare mountain ridges have none of them.
--
-- All spawns are put in a grid of WALK_CELL-yard squares (one square per grid cell that has any,
-- at their average position). Each square is joined to its WALK_NEAREST nearest squares within
-- WALK_LINK yards (both ways), and patrol paths join the squares they pass through. That never
-- changes, so it is worked out once per session, in the background (a few milliseconds per
-- frame), WAIT seconds after logging in. The route planner (Route.lua) uses it as a second, less
-- trusted layer next to the paths you recorded yourself.
--
-- Stored compactly in flat arrays (tens of thousands of squares):
--   ns.walk = {n, X[], Y[], I[] (instance), grid[inst][key] = square,
--              off[], nbr[] (neighbours of i: nbr[off[i] .. off[i + 1] - 1]),
--              patrol[i * PAIR + j] = true}

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local WALK_CELL = 32      -- yards
local WALK_LINK = 160     -- yards: squares this close can be joined ...
local WALK_NEAREST = 5    -- ... each to its this many nearest
local WAIT = 10           -- seconds after login
local PAIR = 1048576

ns.WALK_CELL = WALK_CELL
ns.walk = nil
ns.walkReady = false

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

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

    -- 1. squares from all spawns and patrol points
    local X, Y, I, N, CX, CY = {}, {}, {}, {}, {}, {}
    local grid, n = {}, 0
    local patrol = {}
    local function Add(inst, x, y)
        local cx, cy = floor(x / WALK_CELL), floor(y / WALK_CELL)
        local g = grid[inst]
        if not g then g = {}; grid[inst] = g end
        local key = WalkKey(cx, cy)
        local i = g[key]
        if not i then
            n = n + 1
            i = n
            g[key] = i
            X[i], Y[i], I[i], N[i], CX[i], CY[i] = x, y, inst, 1, cx, cy
        else
            local c = N[i] + 1
            N[i] = c
            X[i] = X[i] + (x - X[i]) / c
            Y[i] = Y[i] + (y - Y[i]) / c
        end
        return i
    end
    local function World(area, x, y)
        local m = areaMap[area]
        if not m or not x or not y or x < 0 or y < 0 then return nil end
        return HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, m)
    end

    local Npc = Q.Npc
    local ok, ids = pcall(Npc.GetAllIds)
    if not ok or type(ids) ~= "table" then return end
    local points = 0
    for _, id in ipairs(ids) do
        local okS, spawns = pcall(Npc.spawns, id)
        if okS and type(spawns) == "table" then
            for area, list in pairs(spawns) do
                for _, p in ipairs(list) do
                    local x, y, inst = World(area, p[1], p[2])
                    if x then Add(inst, x, y) end
                    points = points + 1
                    if points % 200 == 0 then ns.MaybeYield() end
                end
            end
        end
        local okW, ways = pcall(Npc.waypoints, id)
        if okW and type(ways) == "table" then
            for area, paths in pairs(ways) do
                for _, path in ipairs(paths) do
                    local prev, prevInst
                    for _, p in ipairs(path) do
                        local x, y, inst = World(area, p[1], p[2])
                        if x then
                            local i = Add(inst, x, y)
                            if prev and prevInst == inst and prev ~= i then
                                patrol[prev * PAIR + i], patrol[i * PAIR + prev] = true, true
                            end
                            prev, prevInst = i, inst
                        else
                            prev = nil
                        end
                    end
                end
            end
        end
        ns.MaybeYield()
    end
    N = nil

    -- 2. each square's nearest squares (directed lists, WALK_NEAREST per square)
    local reach = floor(WALK_LINK / WALK_CELL) + 1
    local near = {}             -- near[(i - 1) * K + k] = j (0: none)
    local K = WALK_NEAREST
    local candJ, candD = {}, {}
    for i = 1, n do
        local g, cx, cy, xi, yi = grid[I[i]], CX[i], CY[i], X[i], Y[i]
        local nc = 0
        for dx = -reach, reach do
            for dy = -reach, reach do
                local j = g[WalkKey(cx + dx, cy + dy)]
                if j and j ~= i then
                    local ex, ey = X[j] - xi, Y[j] - yi
                    local d = sqrt(ex * ex + ey * ey)
                    if d <= WALK_LINK then
                        nc = nc + 1
                        candJ[nc], candD[nc] = j, d
                    end
                end
            end
        end
        local base = (i - 1) * K
        for k = 1, K do
            local best, bestD = nil, huge
            for c = 1, nc do
                if candD[c] < bestD then best, bestD = c, candD[c] end
            end
            if best then
                near[base + k] = candJ[best]
                candD[best] = huge
            else
                near[base + k] = 0
            end
        end
        if i % 50 == 0 then ns.MaybeYield() end
    end

    -- 3. both ways, without doubles: a pair the other square already listed is skipped
    local function Lists(j, i)
        local b = (j - 1) * K
        for k = 1, K do
            if near[b + k] == i then return true end
        end
        return false
    end
    local deg, PA, PB, np = {}, {}, {}, 0
    for i = 1, n do
        deg[i] = 0
        if i % 5000 == 0 then ns.MaybeYield() end
    end
    for i = 1, n do
        local base = (i - 1) * K
        for k = 1, K do
            local j = near[base + k]
            if j ~= 0 and not (j < i and Lists(j, i)) then
                np = np + 1
                PA[np], PB[np] = i, j
                deg[i], deg[j] = deg[i] + 1, deg[j] + 1
            end
        end
        if i % 500 == 0 then ns.MaybeYield() end
    end
    near = nil
    -- patrol links that aren't among the nearest
    for key in pairs(patrol) do
        local i = floor(key / PAIR)
        local j = key - i * PAIR
        if i < j then
            np = np + 1
            PA[np], PB[np] = i, j
            deg[i], deg[j] = deg[i] + 1, deg[j] + 1
        end
    end

    -- 4. compact neighbour lists
    local off, nbr, fill = {}, {}, {}
    local pos = 1
    for i = 1, n do
        off[i] = pos
        fill[i] = pos
        pos = pos + deg[i]
    end
    off[n + 1] = pos
    deg = nil
    for p = 1, np do
        local a, b = PA[p], PB[p]
        nbr[fill[a]] = b
        fill[a] = fill[a] + 1
        nbr[fill[b]] = a
        fill[b] = fill[b] + 1
        if p % 2000 == 0 then ns.MaybeYield() end
    end

    ns.walk = {n = n, X = X, Y = Y, I = I, grid = grid, off = off, nbr = nbr, patrol = patrol}
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
