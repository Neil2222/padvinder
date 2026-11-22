-- Route planner: when TomTom's arrow has a target (set by you, Questie, ...), find a route there
-- over the recorded paths, flight paths, boats and zeppelins, and let TomTom's arrow point along
-- that route instead of in a straight line. The route is drawn on the minimap and world map
-- (Minimap.lua, Map.lua).
--
-- Graph, over all continents:
--  * every recorded cell is a node. Walked connections can be used both ways, except drops (only
--    ever fallen down). Grinding-only connections and swimming cost a bit more. Nearby cells that
--    aren't connected (parallel tracks of the same road) get a "hop" link.
--  * every flight point you have found is two nodes: on the ground (the flight master) and in the
--    air. Boarding costs some time, air nodes are joined by the flights between them.
--  * every boat/zeppelin/portal dock is a node, joined to where the ride lands.
--  * flight masters and docks are joined to recorded cells near them (walking off-road).
--  * where you have never been: "probable ground" from QuestieDB's spawns and patrol paths
--    (Walkable.lua), trusted less than your own paths.
-- Leaving all of that is allowed but costs more the longer the blind stretch is (Blind): a
-- few yards are fine, a long straight line through unknown land likely runs into a mountain. Costs are in "yards walked": time x running speed.
-- Every stretch of a route is marked sure (your own paths) or not (probable or unknown ground);
-- the map draws the unsure ones dashed and the arrow says "unknown ground".
--
-- All heavy work (building the graph, the search) runs in a coroutine, a few milliseconds per
-- frame, so it never makes the game hitch.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local OFFROAD = 2.0         -- cost factor for a short walk where nothing is known ...
local BLIND_SCALE = 100     -- ... plus 1 for every this many yards of the blind stretch
-- Probable ground (QuestieDB spawns): how much a step between two spawn squares costs grows with
-- the gap between them. Dense spawns (a valley full of mobs) are cheap; a lone mob on a ridge
-- 70 yards from the next is hardly better than walking blind.
local WILD_BASE = 1.2       -- cost factor for a step between squares right next to each other ...
local WILD_PER_YARD = 1/80  -- ... plus this much per yard of gap
local PATROL_FACTOR = 1.2   -- along a patrol path (QuestieDB)
local WALK_LINK = 160       -- yards: probable-ground squares this close can be joined ...
local WALK_NEAREST = 6      -- ... each to its this many nearest (keeps the graph small)
local WILD_FACTOR = WILD_BASE + 16 * WILD_PER_YARD   -- joining probable ground to recorded paths
local JOIN = 16             -- yards: probable ground and recorded paths this close are joined
local SURE_SHORT = 20       -- yards: a stretch this short counts as sure anyway
local GRIND_FACTOR = 1.3    -- connections only walked while grinding (mob areas)
local SWIM_FACTOR = 1.5
local HOP_FACTOR = 1.4      -- jumping between neighbouring tracks
local HOP_MAX = 12          -- yards
local START_RADIUS = 80     -- yards: how far away a path may start
local LINK_RADIUS = 120     -- yards: flight masters and docks are joined to paths this close
local RUN = 7               -- yards a second on foot: turns seconds into yards walked
local FLIGHT_SPEED = 30     -- yards a second along a flight's path
local FLIGHT_STOP = 2       -- seconds per hop on top (taking off, landing)
local FLIGHT_CURVE = 1.4    -- unknown flight: this many times the straight line
local BOARD = 15            -- seconds: talking to the flight master, taking off
local LAND = 3              -- seconds: landing, getting off
local RIDE = { boat = 170, zeppelin = 170, portal = 10 }   -- seconds: waiting plus crossing
local SIMPLIFY = 3          -- yards: route simplification on your own paths ...
local SIMPLIFY_GUESS = 10   -- ... and on guessed stretches (probable ground zigzags between squares)
local LOOKAHEAD = 30        -- yards: the arrow points at the first route point this far from you
local LOOKAHEAD_MAX = 80    -- yards along the route: look no further than this for that point
local BACKTRACK = 3         -- yards: progress along the route may only go back this much
local OFF_ROUTE = 35        -- yards away from the route ...
local OFF_ROUTE_TIME = 2    -- ... for this many seconds: plan again
local REROUTE_MIN = 3       -- seconds between plans
local GRAPH_MAX_AGE = 30    -- seconds: rebuild the graph for new data at most this often
local BUDGET_MS = 3         -- work per frame
local TICK = 0.1
local H_FACTOR = RUN / FLIGHT_SPEED   -- cheapest cost per yard (flying): keeps A* exact

local floor, sqrt, abs, huge, pi, min, max = math.floor, math.sqrt, math.abs, math.huge, math.pi, math.min, math.max
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

local function GridKey(inst, cx, cy)
    return inst * 100000000 + (cx + 5000) * 10000 + (cy + 5000)
end
local PAIR = 1048576
local function Dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return sqrt(dx * dx + dy * dy)
end
-- Cost of walking d yards in a straight line through unknown land.
local function Blind(d)
    return d * (OFFROAD + d / BLIND_SCALE)
end

---------------------------------------------------------------------------------------------
-- Graph

local graph

local function BuildGraph()
    local g = {rev = ns.rev, trev = ns.transportRev, wrev = ns.walkRev, worlds = PadvinderDB.worlds, built = GetTime(),
        X = {}, Y = {}, I = {}, air = {}, rec = {}, grid = {}, wgrid = {}, to = {}, cost = {}, tag = {}, trans = {}}
    local X, Y, I, grid, to, cost, tag = g.X, g.Y, g.I, g.grid, g.to, g.cost, g.tag
    local n = 0
    local function NewNode(x, y, inst)
        n = n + 1
        X[n], Y[n], I[n] = x, y, inst
        to[n], cost[n] = {}, {}
        return n
    end
    local function Link(a, b, c, t)
        local list = to[a]
        local k = #list + 1
        list[k] = b
        cost[a][k] = c
        if t then
            tag[a] = tag[a] or {}
            tag[a][k] = t
        end
    end

    -- recorded cells
    local cellNode = {}   -- [inst][key] = node
    for inst, w in pairs(PadvinderDB.worlds) do
        local ids = {}
        cellNode[inst] = ids
        local k = 0
        for key in pairs(w.cells) do
            local cx, cy = key:match("^(-?%d+):(-?%d+)$")
            local x, y = ns.CellPos(w, key)
            local v = NewNode(x, y, inst)
            g.rec[v] = true
            ids[key] = v
            grid[GridKey(inst, tonumber(cx), tonumber(cy))] = v
            k = k + 1
            if k % 200 == 0 then MaybeYield() end
        end
    end

    -- recorded connections and hops, per world
    for inst, w in pairs(PadvinderDB.worlds) do
        local id = cellNode[inst]
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
        k = 0
        for key, i in pairs(id) do
            local cx, cy = key:match("^(-?%d+):(-?%d+)$")
            cx, cy = tonumber(cx), tonumber(cy)
            for dx = -2, 2 do
                for dy = -2, 2 do
                    local j = grid[GridKey(inst, cx + dx, cy + dy)]
                    -- (no hop i -> j when you once fell from j down to i: that's a climb)
                    if j and j ~= i and not linked[i * PAIR + j] and not dropPair[j * PAIR + i] then
                        local d = Dist(X[i], Y[i], X[j], Y[j])
                        if d <= HOP_MAX then Link(i, j, d * HOP_FACTOR) end
                    end
                end
            end
            k = k + 1
            if k % 100 == 0 then MaybeYield() end
        end
    end

    -- probable ground (QuestieDB): squares, their neighbours, patrol paths, and joins with paths
    local WC = ns.WALK_CELL or 32
    for inst, wl in pairs(ns.walk or {}) do
        local node, wmap = {}, {}
        g.wgrid[inst] = wmap
        for i = 1, wl.n do
            local v = NewNode(wl.X[i], wl.Y[i], inst)
            node[i] = v
            wmap[ns.WalkKey(wl.CX[i], wl.CY[i])] = v
            if i % 300 == 0 then MaybeYield() end
        end
        local WX, WY, WCX, WCY, wgridl = wl.X, wl.Y, wl.CX, wl.CY, wl.grid
        local reach = floor(WALK_LINK / WC) + 1
        local candJ, candD = {}, {}
        for i = 1, wl.n do
            local cx, cy = WCX[i], WCY[i]
            -- the nearest squares around this one, joined both ways
            local nc = 0
            for dx = -reach, reach do
                for dy = -reach, reach do
                    local j = wgridl[ns.WalkKey(cx + dx, cy + dy)]
                    if j and j ~= i then
                        local d = Dist(WX[i], WY[i], WX[j], WY[j])
                        if d <= WALK_LINK then
                            nc = nc + 1
                            candJ[nc], candD[nc] = j, d
                        end
                    end
                end
            end
            for _ = 1, min(WALK_NEAREST, nc) do
                local best = 1
                for c = 2, nc do
                    if candD[c] < candD[best] then best = c end
                end
                local j, d = candJ[best], candD[best]
                candD[best] = huge
                local f = WILD_BASE + d * WILD_PER_YARD
                if d * f < Blind(d) then
                    Link(node[i], node[j], d * f)
                    Link(node[j], node[i], d * f)
                end
            end
            -- join with recorded cells close by
            local rcx, rcy = floor(WX[i] / ns.CELL), floor(WY[i] / ns.CELL)
            local rr = floor(JOIN / ns.CELL) + 1
            for dx = -rr, rr do
                for dy = -rr, rr do
                    local v = grid[GridKey(inst, rcx + dx, rcy + dy)]
                    if v then
                        local d = Dist(WX[i], WY[i], X[v], Y[v])
                        if d <= JOIN then
                            Link(node[i], v, d * WILD_FACTOR)
                            Link(v, node[i], d * WILD_FACTOR)
                        end
                    end
                end
            end
            if i % 100 == 0 then MaybeYield() end
        end
        local pt = wl.patrol
        for k = 1, #pt - 1, 2 do
            local a, b = pt[k], pt[k + 1]
            local d = Dist(WX[a], WY[a], WX[b], WY[b])
            Link(node[a], node[b], d * PATROL_FACTOR)
            Link(node[b], node[a], d * PATROL_FACTOR)
        end
        MaybeYield()
    end

    -- flight points: ground node (the flight master) and air node
    local trans = g.trans
    local airById, nodes = {}, ns.FlightNodes and ns.FlightNodes() or {}
    for _, f in ipairs(nodes) do
        local ground = NewNode(f.x, f.y, f.inst)
        local air = NewNode(f.x, f.y, f.inst)
        g.air[air] = true
        Link(ground, air, BOARD * RUN, {kind = "board", node = f})
        Link(air, ground, LAND * RUN, {kind = "land", node = f})
        airById[f.id] = air
        trans[#trans + 1] = ground
    end
    local FLY = {kind = "fly"}
    local flown, known = ns.TAXI_FLOWN or {}, {}
    for i = 1, #flown - 2, 3 do
        local a, b, yards = flown[i], flown[i + 1], flown[i + 2]
        known[a], known[b] = true, true
        if airById[a] and airById[b] then
            Link(airById[a], airById[b], (yards / FLIGHT_SPEED + FLIGHT_STOP) * RUN, FLY)
        end
    end
    for _, f in ipairs(nodes) do
        local a = airById[f.id]
        -- flight points WoW Forever added: guess flights to the two nearest
        if not known[f.id] then
            local near = {}
            for _, o in ipairs(nodes) do
                if o ~= f and o.inst == f.inst then
                    near[#near + 1] = {o, Dist(f.x, f.y, o.x, o.y)}
                end
            end
            table.sort(near, function(p, q) return p[2] < q[2] end)
            for j = 1, min(2, #near) do
                local o, d = near[j][1], near[j][2]
                local c = (d * FLIGHT_CURVE / FLIGHT_SPEED + FLIGHT_STOP) * RUN
                Link(a, airById[o.id], c, FLY)
                Link(airById[o.id], a, c, FLY)
            end
        end
        -- flights timed before (they may change gryphons on the way)
        if ns.FlightTime then
            for _, o in ipairs(nodes) do
                local t = o ~= f and ns.FlightTime(f.name, o.name)
                if t then Link(a, airById[o.id], t * RUN, FLY) end
            end
        end
    end

    -- boats, zeppelins, portals
    for _, r in ipairs(ns.Rides and ns.Rides() or {}) do
        local from = NewNode(r.fx, r.fy, r.finst)
        local dest = NewNode(r.tx, r.ty, r.tinst)
        Link(from, dest, (RIDE[r.kind] or 170) * RUN, {kind = "ride", ride = r})
        trans[#trans + 1] = from
        trans[#trans + 1] = dest
    end

    -- flight masters and docks: walk off-road to paths and to each other
    local r = floor(LINK_RADIUS / ns.CELL) + 1
    for _, t in ipairs(trans) do
        local inst, tx, ty = I[t], X[t], Y[t]
        local cx, cy = floor(tx / ns.CELL), floor(ty / ns.CELL)
        for dx = -r, r do
            for dy = -r, r do
                local v = grid[GridKey(inst, cx + dx, cy + dy)]
                if v then
                    local d = Dist(tx, ty, X[v], Y[v])
                    if d <= LINK_RADIUS then
                        Link(t, v, Blind(d))
                        Link(v, t, Blind(d))
                    end
                end
            end
        end
        for _, o in ipairs(trans) do
            if o ~= t and I[o] == inst then
                local d = Dist(tx, ty, X[o], Y[o])
                if d <= LINK_RADIUS then Link(t, o, Blind(d)) end
            end
        end
        MaybeYield()
    end
    g.n = n
    return g
end

---------------------------------------------------------------------------------------------
-- Search

-- Returns the legs of the best way from (sx, sy, sinst) to (tx, ty, tinst), or nil:
-- {{kind = "walk"|"air", inst, x = {}, y = {}, action = {...} for the step after a walk}}
local function FindPath(g, sx, sy, sinst, tx, ty, tinst)
    local X, Y, I, to, cost, tag, grid, air = g.X, g.Y, g.I, g.to, g.cost, g.tag, g.grid, g.air
    local gScore, came, via, closed = {}, {}, {}, {}
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
    local function H(v)
        if I[v] ~= tinst then return 0 end
        return Dist(X[v], Y[v], tx, ty) * H_FACTOR
    end
    local function Reach(v, gs, from, t)
        if gs < (gScore[v] or huge) then
            gScore[v], came[v], via[v] = gs, from, t
            Push(gs + H(v), v)
        end
    end

    -- straight there (same continent only)
    local best, bestFrom = huge, nil
    if sinst == tinst then best, bestFrom = Blind(Dist(sx, sy, tx, ty)), 0 end

    -- walk off-road to recorded cells, flight masters and docks near the start
    local r = floor(START_RADIUS / ns.CELL) + 1
    local scx, scy = floor(sx / ns.CELL), floor(sy / ns.CELL)
    for dx = -r, r do
        for dy = -r, r do
            local v = grid[GridKey(sinst, scx + dx, scy + dy)]
            if v then
                local d = Dist(sx, sy, X[v], Y[v])
                if d <= START_RADIUS then Reach(v, Blind(d), 0) end
            end
        end
    end
    for _, t in ipairs(g.trans) do
        if I[t] == sinst then
            local d = Dist(sx, sy, X[t], Y[t])
            if d <= LINK_RADIUS then Reach(t, Blind(d), 0) end
        end
    end
    local wmap = g.wgrid[sinst]
    if wmap then
        local WC = ns.WALK_CELL or 32
        local wr = floor(START_RADIUS / WC) + 1
        local wcx, wcy = floor(sx / WC), floor(sy / WC)
        for dx = -wr, wr do
            for dy = -wr, wr do
                local v = wmap[ns.WalkKey(wcx + dx, wcy + dy)]
                if v then
                    local d = Dist(sx, sy, X[v], Y[v])
                    if d <= START_RADIUS then Reach(v, Blind(d), 0) end
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
            -- leave here and walk straight to the goal
            if I[u] == tinst and not air[u] then
                local c = gu + Blind(Dist(X[u], Y[u], tx, ty))
                if c < best then best, bestFrom = c, u end
            end
            local tu, cu, tg = to[u], cost[u], tag[u]
            for i = 1, #tu do
                Reach(tu[i], gu + cu[i], u, tg and tg[i])
            end
        end
        k = k + 1
        if k % 100 == 0 then MaybeYield() end
    end
    if not bestFrom then return nil end

    -- walk back from where the route leaves for the goal
    local nodes = {}
    local v = bestFrom
    while v and v ~= 0 do
        nodes[#nodes + 1] = v
        v = came[v]
    end

    local legs = {}
    local leg = {kind = "walk", inst = sinst, x = {sx}, y = {sy}, sure = {}}
    legs[1] = leg
    local prev = 0   -- previous node (0: the start)
    -- add a walking point; the stretch to it is sure when it runs between two recorded cells
    local function WalkTo(v, x, y)
        local n = #leg.x
        local short = Dist(leg.x[n], leg.y[n], x, y) <= SURE_SHORT
        leg.sure[n] = short or (v ~= 0 and prev ~= 0 and g.rec[prev] and g.rec[v]) or false
        leg.x[n + 1], leg.y[n + 1] = x, y
    end
    for i = #nodes, 1, -1 do
        local v = nodes[i]
        local t = via[v]
        if not t then
            WalkTo(v, X[v], Y[v])
        elseif t.kind == "board" then
            leg.action = {kind = "flight", from = t.node.short}
            leg = {kind = "air", inst = I[v], x = {X[v]}, y = {Y[v]}}
            legs[#legs + 1] = leg
        elseif t.kind == "fly" then
            leg.x[#leg.x + 1], leg.y[#leg.y + 1] = X[v], Y[v]
        elseif t.kind == "land" then
            for j = #legs, 1, -1 do
                local a = legs[j].action
                if a and a.kind == "flight" and not a.to then a.to = t.node.short break end
            end
            leg = {kind = "walk", inst = I[v], x = {X[v]}, y = {Y[v]}, sure = {}}
            legs[#legs + 1] = leg
        elseif t.kind == "ride" then
            local ride = t.ride
            leg.action = {kind = ride.kind, to = ride.toName}
            if ride.finst == ride.tinst then
                legs[#legs + 1] = {kind = "air", inst = I[v], x = {ride.fx, ride.tx}, y = {ride.fy, ride.ty}}
            end
            leg = {kind = "walk", inst = I[v], x = {X[v]}, y = {Y[v]}, sure = {}}
            legs[#legs + 1] = leg
        end
        prev = v
    end
    WalkTo(0, tx, ty)
    return legs, #nodes
end

-- Douglas-Peucker for a stretch of a route leg (same idea as Segments.lua, on a plain list).
local function SimplifyRun(xs, ys, tol)
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

-- Simplify a walking leg run by run, so sure and unsure stretches keep their own points.
local function SimplifyLeg(leg, tol)
    local xs, ys, sure = leg.x, leg.y, leg.sure
    local ox, oy, os = {xs[1]}, {ys[1]}, {}
    local i, n = 1, #xs
    while i < n do
        local j = i
        while j < n - 1 and sure[j + 1] == sure[i] do j = j + 1 end
        -- points i .. j+1 form one run
        local rx, ry = {}, {}
        for k = i, j + 1 do rx[#rx + 1], ry[#ry + 1] = xs[k], ys[k] end
        rx, ry = SimplifyRun(rx, ry, sure[i] and tol or SIMPLIFY_GUESS)
        for k = 2, #rx do
            os[#ox] = sure[i]
            ox[#ox + 1], oy[#oy + 1] = rx[k], ry[k]
        end
        i = j + 1
    end
    leg.x, leg.y, leg.sure = ox, oy, os
end

---------------------------------------------------------------------------------------------
-- Planning

local goal          -- {x, y, inst, title}
local job           -- running coroutine
local lastPlan = -1000
local planX, planY, planInst
local offSince
local segIdx = 1
local progress = 0        -- yards along the current route, never goes back more than BACKTRACK
local handedOver = false  -- the arrow went back to TomTom for the last stretch
local targetX, targetY, remaining
local hijacked = false
local landed = false

-- The current route (ns.route): the leg being walked now (x, y, cum, n, inst, action) and all
-- legs for drawing (legs). ns.routeRev bumps on change.
ns.routeRev = 0

local function SetRoute(route)
    ns.route = route
    ns.routeRev = ns.routeRev + 1
    segIdx = 1
    progress, handedOver = 0, false
    targetX, targetY, remaining = nil, nil, nil
end

local function Busy()
    return UnitOnTaxi("player") or ns.onTransport
end

local function Plan()
    if not goal then return end
    local x, y, inst = ns.PlayerPos()
    if not x then return end
    lastPlan = GetTime()
    planX, planY, planInst = x, y, inst
    offSince = nil
    local g0 = goal
    job = coroutine.create(function()
        if not graph or graph.worlds ~= PadvinderDB.worlds or graph.trev ~= ns.transportRev
            or graph.wrev ~= ns.walkRev
            or (graph.rev ~= ns.rev and GetTime() - graph.built > GRAPH_MAX_AGE) then
            graph = BuildGraph()
        end
        local legs, nodeCount = FindPath(graph, x, y, inst, g0.x, g0.y, g0.inst)
        if goal ~= g0 then return end   -- target changed meanwhile
        if not legs then
            SetRoute(nil)   -- no way at all (another continent without a known way there)
            return
        end
        for _, leg in ipairs(legs) do
            if leg.kind == "walk" then SimplifyLeg(leg, SIMPLIFY) end
        end
        local first = legs[1]
        local cum = {0}
        for i = 2, #first.x do cum[i] = cum[i - 1] + Dist(first.x[i - 1], first.y[i - 1], first.x[i], first.y[i]) end
        -- (a straight line still gets drawn; its arrow is TomTom's own, see Update)
        SetRoute({x = first.x, y = first.y, cum = cum, n = #first.x, inst = first.inst, sure = first.sure,
            action = first.action, legs = legs, straight = nodeCount == 0})
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
    for i = max(1, segIdx - 1), min(route.n - 1, segIdx + 8) do
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

local function ActionText(action)
    if not action then return nil end
    if action.kind == "flight" then return "Fly to " .. (action.to or "?") end
    if action.kind == "portal" then return "Take the portal to " .. action.to end
    return "Take the " .. action.kind .. " to " .. action.to
end
local WHERE = {flight = "to the flight master", boat = "to the boat", zeppelin = "to the zeppelin", portal = "to the portal"}

---------------------------------------------------------------------------------------------
-- TomTom's arrow

local function Release()
    if hijacked then
        hijacked = false
        if TomTom and TomTom.ReleaseCrazyArrow then
            TomTom:ReleaseCrazyArrow()
            -- TomTom only sets the title when its target changes: put the waypoint's back
            -- (its own update fills in the distance again).
            if goal and TomTom.SetCrazyArrowTitle then
                TomTom:SetCrazyArrowTitle(goal.title or "", "", "")
            end
        end
    end
end

local function ArrowColor(angle)
    -- green straight ahead, yellow sideways, red behind
    local a = abs(angle) % (2 * pi)
    if a > pi then a = 2 * pi - a end
    local p = 1 - a / pi
    if p > 0.5 then return 2 - 2 * p, 1, 0 end
    return 1, 2 * p, 0
end

local function Distance(yards)
    yards = floor(yards + 0.5)
    return TomTom.GetFormattedDistance and TomTom:GetFormattedDistance(yards) or ("%d yards"):format(yards)
end

local textElapsed = 0
local function ArrowOnUpdate(_, elapsed)
    if not targetX then return end
    local x, y = ns.PlayerPos()
    local facing = ns.Facing()
    if not x or not facing then return end   -- hidden (combat): the arrow keeps its direction
    local angle = atan2(targetX - x, targetY - y) - facing
    TomTom:SetCrazyArrowDirection(angle)
    TomTom:SetCrazyArrowColor(ArrowColor(angle))
    textElapsed = textElapsed + (elapsed or 0)
    if textElapsed < 0.2 then return end
    textElapsed = 0
    local route = ns.route
    local action = route and route.action
    if action then
        TomTom:SetCrazyArrowTitle(ActionText(action), Distance(remaining or 0) .. " " .. WHERE[action.kind], "")
    else
        local sure = route and route.sure and route.sure[segIdx]
        TomTom:SetCrazyArrowTitle(goal and goal.title or "Waypoint", Distance(remaining or 0)
            .. (sure and " |cff66ccffvia paths|r" or " |cffffaa00unknown ground|r"), "")
    end
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

    if not PadvinderDB.routing or not goal then
        Release()
        return
    end
    -- in the air or on a boat: TomTom's own arrow until we're back on our feet
    if Busy() then
        Release()
        return
    end
    local x, y, inst, hidden = ns.PlayerPos()
    if not x then
        if not hidden then Release() end   -- hidden for a moment (combat): keep everything as it is
        return
    end
    local now = GetTime()
    local route = ns.route

    -- just landed or got off: plan the rest of the way
    if landed or (route and inst ~= route.inst) then
        if not job and now - lastPlan > 1 then
            landed = false
            Plan()
        end
        Release()
        return
    end

    -- probable ground (QuestieDB) became available after this route was planned
    if graph and graph.wrev ~= ns.walkRev and not job and now - lastPlan > 1 then
        Plan()
    end

    if not route then
        Release()
        -- no route (no way known): try again after a change
        if not job and now - lastPlan > REROUTE_MIN
            and (inst ~= planInst or Dist(x, y, planX or x, planY or y) > 100) then
            Plan()
        end
        return
    end

    local along, off = Progress(route, x, y)
    -- Walking beside a zigzag, the nearest bit of route can lie behind you: don't go back.
    if along < progress - BACKTRACK then along = progress - BACKTRACK end
    if along > progress then progress = along end
    if off > OFF_ROUTE then
        offSince = offSince or now
        if now - offSince > OFF_ROUTE_TIME and now - lastPlan > REROUTE_MIN and not job then Plan() end
    else
        offSince = nil
    end

    remaining = route.cum[route.n] - along + off
    -- The arrow's target: the first point along the route at least LOOKAHEAD yards from you (so
    -- walking a few yards beside the line it still points forward, not at the line).
    local ahead = along + LOOKAHEAD
    for a = along + 5, along + LOOKAHEAD_MAX, 5 do
        local tx, ty = PointAt(route, a)
        if Dist(x, y, tx, ty) >= LOOKAHEAD then ahead = a break end
    end
    targetX, targetY = PointAt(route, ahead)

    -- On the last straight stretch to the goal the route is the straight line: TomTom's own arrow
    -- (with its arrival animation) does that best. Not when a flight or boat comes next.
    if handedOver or (segIdx >= route.n - 1 and not route.action) then
        handedOver = true   -- (stays handed over: no flipping back and forth at the last bend)
        Release()
    elseif not hijacked and CanHijack() then
        hijacked = true
        TomTom:HijackCrazyArrow(ArrowOnUpdate)
    end
end

function ns.OnLanded()
    landed = true
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
    if not Busy() then Plan() end
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
        local action = ns.route.action
        if action then
            return ("%s, %d yards %s"):format(ActionText(action), floor(remaining + 0.5), WHERE[action.kind])
        end
        if ns.route.straight then return ("%d yards, straight (unknown ground)"):format(floor(remaining + 0.5)) end
        return ("%d yards via paths"):format(floor(remaining + 0.5))
    elseif goal then
        return "no way known"
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
