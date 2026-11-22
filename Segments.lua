-- Turns the recorded connections of one world into drawable segments, shared by the world map
-- and the minimap: undirected (a walked-both-ways road is one segment), with a colour class.
--
-- Colour classes: 0..HEAT_STEPS = heat buckets (yellow -> red), "drop" (only ever fallen down,
-- blue), "fight" (only walked during/just after combat, purple).

local ADDON, ns = ...

local HEAT_STEPS = 5
local log, min, max, floor = math.log, math.min, math.max, math.floor

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
    if cls == "drop" then return 0.4, 0.7, 1, 0.8 end
    if cls == "fight" then return 0.75, 0.4, 1, 0.55 end
    local t = cls / HEAT_STEPS
    return 1, 1 - 0.9 * t, 0.2 - 0.2 * t, 0.6 + 0.35 * t
end

-- Does a segment belong in the given map mode ("all", "travel", "grind")?
function ns.InMode(isFight, mode)
    return mode == "all" or (mode == "travel" and not isFight) or (mode == "grind" and isFight)
end

local cache = {}   -- [inst] = segments, rebuilt when ns.rev changes

-- Returns {n, a[], b[], cls[], fight[], x1[], y1[], x2[], y2[]} (world yards), or nil.
function ns.Segments(inst)
    local w = PadvinderDB.worlds[inst]
    if not w then cache[inst] = nil return nil end
    local seg = cache[inst]
    if seg and seg.rev == ns.rev then return seg end

    local edges, drops, fight = w.edges, w.drops, w.fight
    local cells, fightCells = w.cells, w.fightCells

    -- Heat of a cell = how often the area around it (3x3 cells) was walked while travelling.
    -- Walking the same road twice rarely hits exactly the same cells, but it does hit the same
    -- neighbourhood.
    local heatCache = {}
    local function Travel(k)
        local c = cells[k]
        return c and (c - (fightCells[k] or 0)) or 0
    end
    local function Heat(key)
        local h = heatCache[key]
        if not h then
            local cx, cy = key:match("^(-?%d+):(-?%d+)$")
            cx, cy = tonumber(cx), tonumber(cy)
            local sum = 0
            for i = -1, 1 do
                for j = -1, 1 do
                    sum = sum + Travel((cx + i) .. ":" .. (cy + j))
                end
            end
            h = sum / 3   -- one pass touches ~3 cells in the neighbourhood
            heatCache[key] = h
        end
        return h
    end

    seg = {rev = ns.rev, a = {}, b = {}, cls = {}, fight = {}, x1 = {}, y1 = {}, x2 = {}, y2 = {}}
    local n = 0
    for ek, count in pairs(edges) do
        local a, b = Split(ek)
        local rk = b .. ">" .. a
        local reverse = edges[rk]
        if not reverse or a < b then
            local travel = count - (fight[ek] or 0) + (reverse and (reverse - (fight[rk] or 0)) or 0)
            local isFight = travel <= 0
            local cls
            if drops[ek] and not reverse then
                cls = "drop"
            elseif isFight then
                cls = "fight"
            else
                cls = HeatBucket((Heat(a) + Heat(b)) / 2)
            end
            n = n + 1
            seg.a[n], seg.b[n], seg.cls[n], seg.fight[n] = a, b, cls, isFight
            seg.x1[n], seg.y1[n] = ns.CellPos(w, a)
            seg.x2[n], seg.y2[n] = ns.CellPos(w, b)
        end
    end
    seg.n = n
    cache[inst] = seg
    return seg
end
