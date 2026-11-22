-- Turns the recorded connections of one world into drawable segments and polylines, shared by
-- the world map and the minimap: undirected (a walked-both-ways road is one segment), with a
-- colour class.
--
-- Colour classes: 0..HEAT_STEPS = heat buckets (yellow -> red), "drop" (only ever fallen down,
-- blue), "fight" (only walked during/just after combat, purple).

local ADDON, ns = ...

local HEAT_STEPS = 5
local BUDGET_MS = 3   -- work per frame for builds that run in a coroutine
local log, min, max, floor = math.log, math.min, math.max, math.floor

-- Time slicing for heavy builds. Code running in a coroutine calls ns.MaybeYield() now and then;
-- it gives the frame back once BUDGET_MS is used up. Outside a coroutine it does nothing, so the
-- same functions also work in one go (the world map).
local function Clock()
    return debugprofilestop and debugprofilestop() or os.clock() * 1000
end
local sliceStart = 0
function ns.SliceStart() sliceStart = Clock() end
function ns.MaybeYield()
    if Clock() - sliceStart > BUDGET_MS then
        local co, isMain = coroutine.running()
        if co and not isMain then
            coroutine.yield()
            sliceStart = Clock()
        end
    end
end

-- Cache split edge keys
local splitCache = {}
local function Split(ek)
    local s = splitCache[ek]
    if not s then
        local a, b = ek:match("^(.-)>(.+)$")
        s = {a, b}
        splitCache[ek] = s
    end
    return s[1], s[2]
end
ns.SplitEdge = Split

local function HeatBucket(heat)
    -- 1 pass = yellow, 2 = orange, ~6+ = red
    local t = min(1, log(max(1, heat)) / log(6))
    return floor(t * HEAT_STEPS + 0.5)
end

function ns.ClassColor(cls)
    if cls == "route" then return 0.2, 0.95, 1, 1 end         -- planned route, walking (Route.lua)
    if cls == "routeAir" then return 1, 0.82, 0.25, 0.9 end   -- planned route, flight/boat/zeppelin
    if cls == "routeGuess" then return 0.2, 0.95, 1, 0.75 end -- planned route over unknown ground (dashed)
    if cls == "drop" then return 0.4, 0.7, 1, 0.8 end
    if cls == "fight" then return 0.75, 0.4, 1, 0.55 end
    local t = cls / HEAT_STEPS
    return 1, 1 - 0.9 * t, 0.2 - 0.2 * t, 0.6 + 0.35 * t
end

-- Calls line(x1, y1, x2, y2) for the dashes of a line: dash long, gap between them.
function ns.Dashes(x1, y1, x2, y2, dash, gap, line)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return end
    local ux, uy = dx / len, dy / len
    local s = 0
    while s < len do
        local e = math.min(len, s + dash)
        line(x1 + ux * s, y1 + uy * s, x1 + ux * e, y1 + uy * e)
        s = e + gap
    end
end

-- Does a segment belong in the given map mode ("all", "travel", "grind")?
function ns.InMode(isFight, mode)
    return mode == "all" or (mode == "travel" and not isFight) or (mode == "grind" and isFight)
end

-- Heat of a cell = how often the area around it (3x3 cells) was walked while travelling.
-- Walking the same road twice rarely hits exactly the same cells, but it does hit the same
-- neighbourhood.
local function Heat(w, key, cache)
    local h = cache and cache[key]
    if not h then
        local cells, fightCells = w.cells, w.fightCells
        local cx, cy = key:match("^(-?%d+):(-?%d+)$")
        cx, cy = tonumber(cx), tonumber(cy)
        local sum = 0
        for i = -1, 1 do
            for j = -1, 1 do
                local k = (cx + i) .. ":" .. (cy + j)
                local c = cells[k]
                if c then sum = sum + c - (fightCells[k] or 0) end
            end
        end
        h = sum / 3   -- one pass touches ~3 cells in the neighbourhood
        if cache then cache[key] = h end
    end
    return h
end

-- Colour class and grinding flag of the connection a-b (ek = "a>b", the reverse may exist too).
local function Classify(w, ek, a, b, cache)
    local edges, fight = w.edges, w.fight
    local rk = b .. ">" .. a
    local reverse = edges[rk]
    local travel = (edges[ek] or 0) - (fight[ek] or 0) + (reverse and (reverse - (fight[rk] or 0)) or 0)
    local isFight = travel <= 0
    if w.drops[ek] and not reverse then return "drop", isFight end
    if isFight then return "fight", true end
    return HeatBucket((Heat(w, a, cache) + Heat(w, b, cache)) / 2), false
end

function ns.ClassifyEdge(w, ek)
    local a, b = Split(ek)
    return Classify(w, ek, a, b)
end

local cache = {}   -- [inst] = segments, rebuilt when ns.rev changes

-- Returns {n, a[], b[], cls[], fight[]} for one world, or nil.
function ns.Segments(inst)
    local w = PadvinderDB.worlds[inst]
    if not w then cache[inst] = nil return nil end
    local seg = cache[inst]
    if seg and seg.rev == ns.rev and seg.w == w then return seg end

    local edges = w.edges
    local heatCache = {}
    seg = {rev = ns.rev, w = w, a = {}, b = {}, cls = {}, fight = {}}
    local n = 0
    for ek in pairs(edges) do
        local a, b = Split(ek)
        if not edges[b .. ">" .. a] or a < b then
            n = n + 1
            seg.a[n], seg.b[n] = a, b
            seg.cls[n], seg.fight[n] = Classify(w, ek, a, b, heatCache)
            if n % 200 == 0 then ns.MaybeYield() end
        end
    end
    seg.n = n
    cache[inst] = seg
    return seg
end

-- Douglas-Peucker on parallel x/y arrays; returns the kept indices in order.
local function Simplify(xs, ys, tol)
    local n = #xs
    if n <= 2 then return {1, n} end
    local keep = {[1] = true, [n] = true}
    local stack = {1, n}
    local tol2 = tol * tol
    while #stack > 0 do
        local last = stack[#stack]; stack[#stack] = nil
        local first = stack[#stack]; stack[#stack] = nil
        local x1, y1, x2, y2 = xs[first], ys[first], xs[last], ys[last]
        local dx, dy = x2 - x1, y2 - y1
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
    local out = {}
    for i = 1, n do if keep[i] then out[#out + 1] = i end end
    return out
end

-- Joins the segments for which include(i) is true into chains of the same colour (also across
-- junctions: a polyline may branch off later), simplifies them with tolerance `tol` in the units
-- of Pos(cellKey) -> x, y, and calls emit(xs, ys, keptIndices, cls) per chain.
-- emit may return false to stop.
function ns.Polylines(seg, include, Pos, tol, emit)
    local ea, eb, ecls, eused = {}, {}, {}, {}
    local adj = {}   -- adj[cls][node] = {edge indices}
    local n = 0
    for i = 1, seg.n do
        if include(i) then
            local a, b, cls = seg.a[i], seg.b[i], seg.cls[i]
            n = n + 1
            ea[n], eb[n], ecls[n] = a, b, cls
            local byNode = adj[cls]
            if not byNode then byNode = {}; adj[cls] = byNode end
            local la = byNode[a]; if not la then la = {}; byNode[a] = la end
            local lb = byNode[b]; if not lb then lb = {}; byNode[b] = lb end
            la[#la + 1] = n
            lb[#lb + 1] = n
            if n % 500 == 0 then ns.MaybeYield() end
        end
    end

    -- Follow a chain from `node` through any not-yet-used connection of the same colour.
    local function Extend(chain, node, cls)
        local byNode = adj[cls]
        while true do
            local list = byNode[node]
            local nxt
            if list then
                for k = 1, #list do
                    local e = list[k]
                    if not eused[e] then nxt = e; break end
                end
            end
            if not nxt then return end
            eused[nxt] = true
            node = ea[nxt] == node and eb[nxt] or ea[nxt]
            chain[#chain + 1] = node
        end
    end

    for i = 1, n do
        if not eused[i] then
            eused[i] = true
            local cls = ecls[i]
            local fwd = {ea[i], eb[i]}
            Extend(fwd, eb[i], cls)
            local back = {}
            Extend(back, ea[i], cls)
            -- chain = reverse(back) .. fwd
            local xs, ys = {}, {}
            for j = #back, 1, -1 do
                local x, y = Pos(back[j]); xs[#xs + 1] = x; ys[#ys + 1] = y
            end
            for j = 1, #fwd do
                local x, y = Pos(fwd[j]); xs[#xs + 1] = x; ys[#ys + 1] = y
            end
            if emit(xs, ys, Simplify(xs, ys, tol), cls) == false then return end
            if i % 50 == 0 then ns.MaybeYield() end
        end
    end
end
