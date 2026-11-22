-- Route planner: when TomTom's arrow has a target (set by you, Questie, ...), find a route there
-- over the recorded paths and let TomTom's arrow point along that route instead of in a straight
-- line. The route is drawn on the minimap and world map (Minimap.lua, Map.lua).
--
-- Graph: every recorded cell is a node. Walked connections can be used both ways, except
-- drops (only ever fallen down). Grinding-only connections and swimming cost a bit more.
-- Nearby cells that aren't connected (parallel tracks of the same road) get a "hop" link.
-- Leaving the paths is allowed but costs OFFROAD times the distance, so the route sticks to
-- the paths unless cutting across saves a lot.
--
-- All heavy work (building the graph, A*) runs in a coroutine, a few milliseconds per frame,
-- so it never makes the game hitch.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local OFFROAD = 2.0         -- cost factor for walking where nothing was recorded
local GRIND_FACTOR = 1.3    -- connections only walked while grinding (mob areas)
local SWIM_FACTOR = 1.5
local HOP_FACTOR = 1.4      -- jumping between neighbouring tracks
local HOP_MAX = 12          -- yards
local START_RADIUS = 80     -- yards: how far away a path may start
local SIMPLIFY = 2          -- yards, route simplification
local LOOKAHEAD = 20        -- yards: the arrow points this far ahead along the route
local OFF_ROUTE = 35        -- yards away from the route ...
local OFF_ROUTE_TIME = 2    -- ... for this many seconds: plan again
local REROUTE_MIN = 3       -- seconds between plans
local GRAPH_MAX_AGE = 30    -- seconds: rebuild the graph for new data at most this often
local BUDGET_MS = 3         -- work per frame
local TICK = 0.1

local floor, sqrt, abs, huge, pi = math.floor, math.sqrt, math.abs, math.huge, math.pi
local atan2 = math.atan2 or math.atan

local function Clock()
    return debugprofilestop and debugprofilestop() or os.clock() * 1000
end

-- Coroutine time slicing
local sliceStart = 0
local function MaybeYield()
    if Clock() - sliceStart > BUDGET_MS then
        coroutine.yield()
        sliceStart = Clock()
    end
end

local function GridKey(cx, cy)
    return (cx + 5000) * 10000 + (cy + 5000)
end
local PAIR = 1048576
local function Dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------------------------
-- Graph

local graph

local function BuildGraph(inst, w)
    local g = {inst = inst, w = w, rev = ns.rev, built = GetTime(),
        X = {}, Y = {}, CX = {}, CY = {}, id = {}, grid = {}, to = {}, cost = {}}
    local X, Y, id, grid, to, cost = g.X, g.Y, g.id, g.grid, g.to, g.cost
    local n = 0
    for key in pairs(w.cells) do
        n = n + 1
        local cx, cy = key:match("^(-?%d+):(-?%d+)$")
        cx, cy = tonumber(cx), tonumber(cy)
        id[key] = n
        X[n], Y[n] = ns.CellPos(w, key)
        g.CX[n], g.CY[n] = cx, cy
        grid[GridKey(cx, cy)] = n
        to[n], cost[n] = {}, {}
        if n % 200 == 0 then MaybeYield() end
    end
    g.n = n

    local function Link(a, b, c)
        local t = to[a]
        t[#t + 1] = b
        cost[a][#t] = c
    end

    -- recorded connections
    local edges, drops, fight, swim = w.edges, w.drops, w.fight, w.swim
    local linked, dropPair = {}, {}
    local k = 0
    for ek, count in pairs(edges) do
        local ka, kb = ns.SplitEdge(ek)
        local a, b = id[ka], id[kb]
        local rk = kb .. ">" .. ka
        local reverse = edges[rk]
        if a and b and (not reverse or ka < kb) then
            local travel = count - (fight[ek] or 0) + (reverse and (reverse - (fight[rk] or 0)) or 0)
            local f = travel <= 0 and GRIND_FACTOR or 1
            if swim[ka] or swim[kb] then f = f * SWIM_FACTOR end
            local c = Dist(X[a], Y[a], X[b], Y[b]) * f
            Link(a, b, c)
            if reverse or not drops[ek] then
                Link(b, a, c)
            else
                dropPair[a * PAIR + b] = true   -- fell from a down to b
            end
            linked[a * PAIR + b], linked[b * PAIR + a] = true, true
        end
        k = k + 1
        if k % 200 == 0 then MaybeYield() end
    end

    -- hops between nearby, unconnected cells (parallel tracks)
    local CX, CY = g.CX, g.CY
    for i = 1, n do
        local cx, cy = CX[i], CY[i]
        for dx = -2, 2 do
            for dy = -2, 2 do
                local j = grid[GridKey(cx + dx, cy + dy)]
                if j and j ~= i and not linked[i * PAIR + j] and not dropPair[j * PAIR + i] then
                    -- (no hop i -> j when you once fell from j down to i: that's a climb)
                    local d = Dist(X[i], Y[i], X[j], Y[j])
                    if d <= HOP_MAX then Link(i, j, d * HOP_FACTOR) end
                end
            end
        end
        if i % 100 == 0 then MaybeYield() end
    end
    return g
end

---------------------------------------------------------------------------------------------
-- A*

-- Returns the route points (world yards) from (sx, sy) to (tx, ty), or nil.
local function FindPath(g, sx, sy, tx, ty)
    local X, Y, to, cost, grid = g.X, g.Y, g.to, g.cost, g.grid
    local gScore, came, closed = {}, {}, {}
    local hf, hn, size = {}, {}, 0   -- binary min-heap of (f, node)

    local function Push(f, v)
        size = size + 1
        local i = size
        while i > 1 do
            local p = floor(i / 2)
            if hf[p] <= f then break end
            hf[i], hn[i] = hf[p], hn[p]
            i = p
        end
        hf[i], hn[i] = f, v
    end
    local function Pop()
        local f, v = hf[1], hn[1]
        local lf, lv = hf[size], hn[size]
        hf[size], hn[size] = nil, nil
        size = size - 1
        if size > 0 then
            local i = 1
            while true do
                local c = i * 2
                if c > size then break end
                if c < size and hf[c + 1] < hf[c] then c = c + 1 end
                if hf[c] >= lf then break end
                hf[i], hn[i] = hf[c], hn[c]
                i = c
            end
            hf[i], hn[i] = lf, lv
        end
        return f, v
    end

    -- straight there is always possible
    local best, bestFrom = OFFROAD * Dist(sx, sy, tx, ty), 0

    -- walk off-road to any recorded cell near the start
    local r = floor(START_RADIUS / ns.CELL) + 1
    local scx, scy = floor(sx / ns.CELL), floor(sy / ns.CELL)
    for dx = -r, r do
        for dy = -r, r do
            local v = grid[GridKey(scx + dx, scy + dy)]
            if v then
                local d = Dist(sx, sy, X[v], Y[v])
                if d <= START_RADIUS then
                    local gs = d * OFFROAD
                    if gs < (gScore[v] or huge) then
                        gScore[v], came[v] = gs, 0
                        Push(gs + Dist(X[v], Y[v], tx, ty), v)
                    end
                end
            end
        end
    end

    local k = 0
    while size > 0 do
        local f, u = Pop()
        if f >= best then break end   -- nothing left can beat the best way to the goal
        if not closed[u] then
            closed[u] = true
            local gu = gScore[u]
            local xu, yu = X[u], Y[u]
            -- leave the paths here and walk straight to the goal
            local c = gu + OFFROAD * Dist(xu, yu, tx, ty)
            if c < best then best, bestFrom = c, u end
            local tu, cu = to[u], cost[u]
            for i = 1, #tu do
                local v = tu[i]
                local ng = gu + cu[i]
                if ng < (gScore[v] or huge) then
                    gScore[v], came[v] = ng, u
                    Push(ng + Dist(X[v], Y[v], tx, ty), v)
                end
            end
        end
        k = k + 1
        if k % 100 == 0 then MaybeYield() end
    end

    -- walk back from the last path cell
    local nodes = {}
    local v = bestFrom
    while v and v ~= 0 do
        nodes[#nodes + 1] = v
        v = came[v]
    end
    local xs, ys = {sx}, {sy}
    for i = #nodes, 1, -1 do
        xs[#xs + 1], ys[#ys + 1] = X[nodes[i]], Y[nodes[i]]
    end
    xs[#xs + 1], ys[#ys + 1] = tx, ty
    return xs, ys, #nodes
end

-- Douglas-Peucker for the route (same idea as Segments.lua, on a plain list).
local function SimplifyRoute(xs, ys, tol)
    local n = #xs
    if n <= 2 then return xs, ys end
    local keep = {[1] = true, [n] = true}
    local stack = {1, n}
    local tol2 = tol * tol
    while #stack > 0 do
        local last = stack[#stack]; stack[#stack] = nil
        local first = stack[#stack]; stack[#stack] = nil
        local x1, y1 = xs[first], ys[first]
        local dx, dy = xs[last] - x1, ys[last] - y1
        local len2 = dx * dx + dy * dy
        local worst, worstD = nil, tol2
        for i = first + 1, last - 1 do
            local px, py = xs[i] - x1, ys[i] - y1
            local d
            if len2 == 0 then
                d = px * px + py * py
            else
                local cross = px * dy - py * dx
                d = cross * cross / len2
            end
            if d > worstD then worst, worstD = i, d end
        end
        if worst then
            keep[worst] = true
            stack[#stack + 1] = first; stack[#stack + 1] = worst
            stack[#stack + 1] = worst; stack[#stack + 1] = last
        end
    end
    local ox, oy = {}, {}
    for i = 1, n do
        if keep[i] then ox[#ox + 1], oy[#oy + 1] = xs[i], ys[i] end
    end
    return ox, oy
end

---------------------------------------------------------------------------------------------
-- Planning

local goal          -- {x, y, inst, title}
local job           -- running coroutine
local lastPlan = -1000
local planX, planY, planInst
local offSince
local segIdx = 1
local targetX, targetY, remaining
local hijacked = false

-- The current route: ns.route = {x = {}, y = {}, cum = {}, n, inst}; ns.routeRev bumps on change.
ns.routeRev = 0

local function SetRoute(route)
    ns.route = route
    ns.routeRev = ns.routeRev + 1
    segIdx = 1
    targetX, targetY, remaining = nil, nil, nil
end

local function Plan()
    if not goal then return end
    local x, y, inst = HBD:GetPlayerWorldPosition()
    if not x or inst ~= goal.inst then
        planInst = inst
        SetRoute(nil)
        return
    end
    lastPlan = GetTime()
    planX, planY, planInst = x, y, inst
    offSince = nil
    local g0 = goal
    job = coroutine.create(function()
        local w = PadvinderDB.worlds[inst]
        if not w then SetRoute(nil) return end
        if not graph or graph.inst ~= inst or graph.w ~= w
            or (graph.rev ~= ns.rev and GetTime() - graph.built > GRAPH_MAX_AGE) then
            graph = BuildGraph(inst, w)
        end
        local xs, ys, roadNodes = FindPath(graph, x, y, g0.x, g0.y)
        if goal ~= g0 then return end   -- target changed meanwhile
        if roadNodes == 0 then
            SetRoute(nil)   -- straight there is best: TomTom's own arrow does that
            return
        end
        xs, ys = SimplifyRoute(xs, ys, SIMPLIFY)
        local cum = {0}
        for i = 2, #xs do cum[i] = cum[i - 1] + Dist(xs[i - 1], ys[i - 1], xs[i], ys[i]) end
        SetRoute({x = xs, y = ys, cum = cum, n = #xs, inst = inst})
    end)
end

-- Point at distance `along` on the route.
local function PointAt(route, along)
    local xs, ys, cum = route.x, route.y, route.cum
    for i = 2, route.n do
        if cum[i] >= along then
            local len = cum[i] - cum[i - 1]
            local t = len > 0 and (along - cum[i - 1]) / len or 0
            return xs[i - 1] + (xs[i] - xs[i - 1]) * t, ys[i - 1] + (ys[i] - ys[i - 1]) * t
        end
    end
    return xs[route.n], ys[route.n]
end

-- Where is the player along the route? Sets segIdx, returns along, distance from the route.
local function Progress(route, x, y)
    local xs, ys, cum = route.x, route.y, route.cum
    local bestD, bestI, bestT = huge, segIdx, 0
    for i = math.max(1, segIdx - 1), math.min(route.n - 1, segIdx + 8) do
        local x1, y1 = xs[i], ys[i]
        local dx, dy = xs[i + 1] - x1, ys[i + 1] - y1
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and ((x - x1) * dx + (y - y1) * dy) / len2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local d = Dist(x, y, x1 + t * dx, y1 + t * dy)
        if d < bestD then bestD, bestI, bestT = d, i, t end
    end
    segIdx = bestI
    return cum[bestI] + bestT * (cum[bestI + 1] - cum[bestI]), bestD
end

-- Where the route line should start: the player's spot on the route.
function ns.RouteStart()
    return segIdx
end

---------------------------------------------------------------------------------------------
-- TomTom's arrow

local function Release()
    if hijacked then
        hijacked = false
        if TomTom and TomTom.ReleaseCrazyArrow then TomTom:ReleaseCrazyArrow() end
    end
end

local function ArrowColor(angle)
    -- green straight ahead, yellow sideways, red behind
    local a = abs(angle)
    if a > pi then a = 2 * pi - a end
    local p = 1 - a / pi
    if p > 0.5 then return 2 - 2 * p, 1, 0 end
    return 1, 2 * p, 0
end

local textElapsed = 0
local function ArrowOnUpdate(_, elapsed)
    if not targetX then return end
    local x, y = HBD:GetPlayerWorldPosition()
    local facing = GetPlayerFacing()
    if not x or not facing then return end
    local angle = atan2(targetX - x, targetY - y) - facing
    TomTom:SetCrazyArrowDirection(angle)
    TomTom:SetCrazyArrowColor(ArrowColor(angle))
    textElapsed = textElapsed + (elapsed or 0)
    if textElapsed < 0.2 then return end
    textElapsed = 0
    local dist = remaining or 0
    local text = TomTom.GetFormattedDistance and TomTom:GetFormattedDistance(dist) or ("%d yards"):format(floor(dist + 0.5))
    TomTom:SetCrazyArrowTitle(goal and goal.title or "Waypoint", text .. " |cff66ccffvia paths|r", "")
end

local function CanHijack()
    if not (TomTom and TomTom.HijackCrazyArrow) then return false end
    if TomTom.profile and TomTom.profile.arrow and TomTom.profile.arrow.enable == false then return false end
    return hijacked or not TomTom:CrazyArrowIsHijacked()
end

---------------------------------------------------------------------------------------------
-- Update loop

local function Update()
    if job then
        sliceStart = Clock()
        local ok, err = coroutine.resume(job)
        if not ok then
            job = nil
            ns.Print("route planning failed: " .. tostring(err))
        elseif coroutine.status(job) == "dead" then
            job = nil
        end
    end

    local route = ns.route
    if not PadvinderDB.routing or not goal then
        Release()
        return
    end
    local x, y, inst = HBD:GetPlayerWorldPosition()
    if not x then
        Release()
        return
    end
    if not route then
        Release()
        -- no route (other continent, or straight was best): try again after a change
        if not job and GetTime() - lastPlan > REROUTE_MIN
            and (inst ~= planInst or Dist(x, y, planX or x, planY or y) > 100) then
            Plan()
        end
        return
    end
    if inst ~= route.inst then
        Release()
        return
    end

    local along, off = Progress(route, x, y)
    local now = GetTime()
    if off > OFF_ROUTE then
        offSince = offSince or now
        if now - offSince > OFF_ROUTE_TIME and now - lastPlan > REROUTE_MIN and not job then Plan() end
    else
        offSince = nil
    end

    remaining = route.cum[route.n] - along + off
    targetX, targetY = PointAt(route, along + LOOKAHEAD)

    -- On the last straight stretch the route is the straight line: TomTom's own arrow (with
    -- its arrival animation) does that best.
    if segIdx >= route.n - 1 then
        Release()
    elseif not hijacked and CanHijack() then
        hijacked = true
        TomTom:HijackCrazyArrow(ArrowOnUpdate)
    end
end

local function OnTarget(_, uid)
    if not PadvinderDB then return end
    goal = nil
    job = nil
    SetRoute(nil)
    Release()
    if not uid or not PadvinderDB.routing then return end
    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(uid[2], uid[3], uid[1])
    if not wx then return end
    goal = {x = wx, y = wy, inst = inst, title = uid.title}
    Plan()
end

function ns.SetRouting(on)
    PadvinderDB.routing = on
    ns.Print("route planner: " .. (on and "|cff00ff00on|r" or "|cffff4444off|r") .. ".")
    if not on then
        goal, job = nil, nil
        SetRoute(nil)
        Release()
    else
        ns.Print("it starts with the next TomTom/Questie waypoint you set.")
    end
end

function ns.RouteInfo()
    if not (TomTom and TomTom.RegisterCallback) then
        return "needs TomTom"
    elseif not PadvinderDB.routing then
        return "off"
    elseif job then
        return "planning..."
    elseif ns.route and remaining then
        return ("%d yards via paths"):format(floor(remaining + 0.5))
    elseif goal then
        return "straight line (no better way over paths)"
    end
    return "no waypoint"
end

-- Register right away (TomTom loads first, see OptionalDeps), so a waypoint TomTom restores
-- while logging in isn't missed.
if TomTom and TomTom.RegisterCallback then
    TomTom.RegisterCallback(ns, "ArrowTargetChanged", OnTarget)
    local f = CreateFrame("Frame")
    local acc = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        if not PadvinderDB then return end
        acc = acc + elapsed
        if acc >= TICK or job then
            acc = 0
            Update()
        end
    end)
end
