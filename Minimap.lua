-- Draws the recorded paths on the minimap, around the player, in the same colours as the
-- world map. Follows minimap zoom, indoor/outdoor scale and "rotate minimap". Lines are
-- clipped at the minimap's edge (round, or square when an addon makes the minimap square).
--
-- Performance (the minimap is drawn while you play, so this must never hitch):
--  * The full picture is built only on login, a new continent, a new map mode or a wipe:
--    connections are joined into chains and simplified, so a straight road is one line. That
--    build runs in a coroutine, a few milliseconds per frame.
--  * Newly walked connections are added one by one (ns.OnNewEdge), no rebuild.
--  * Pieces sit in a spatial index (BUCKET-yard squares); an update only looks at those near
--    the player, and only when the picture changed (moved half a pixel, turned, zoomed).

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2          -- line width in minimap units (~pixels)
local ROUTE_THICKNESS = 3    -- the planned route (Route.lua)
local MAX_LINES = 3000
local BUCKET = 64            -- spatial index square size in yards
local SIMPLIFY = 0.75        -- max deviation in yards when simplifying chains
local UPDATE_RATE = 30       -- max redraws per second
local MOVE_PIXELS = 0.5      -- redraw when the player moved this many minimap pixels
local EDGE = 0.95            -- clip at this fraction of the radius, just inside the border
local HOLE = 9               -- no lines within this many minimap units of the player arrow
local DASH, GAP = 5, 4       -- minimap units: unsure stretches of the route are dashed

-- Diameter of the minimap in yards per zoom level, for clients without C_Minimap.GetViewRadius.
local MINIMAP_SIZE = {
    indoor  = {[0] = 300, 240, 180, 120, 80, 50},
    outdoor = {[0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3},
}

local floor, sqrt, sin, cos, abs, min, max = math.floor, math.sqrt, math.sin, math.cos, math.abs, math.min, math.max

local overlay
local lines, used = {}, 0
local routeLines, routeUsed = {}, 0
local drawnRouteRev

-- Drawn pieces (world yards) and the spatial index: buckets[key] = {piece indices}.
-- A set holds them for one continent; the one being drawn is "live", its arrays are upvalues.
local px1, py1, px2, py2, pcls, stamp, buckets
local live
local drawId = 0
local indexInst, indexW, indexMode
local buildJob, pending   -- running rebuild, connections walked meanwhile
local dirty = true
local sinceUpdate = 0
local lastX, lastY, lastFacing, lastRadius, lastWidth, lastSquare

local function BucketKey(bx, by)
    return (bx + 50000) * 100000 + (by + 50000)
end

local function NewSet(inst)
    return {inst = inst, n = 0, x1 = {}, y1 = {}, x2 = {}, y2 = {}, cls = {}, stamp = {}, buckets = {}}
end

local function Use(set)
    live = set
    px1, py1, px2, py2, pcls, stamp, buckets = set.x1, set.y1, set.x2, set.y2, set.cls, set.stamp, set.buckets
    dirty = true
end
Use(NewSet())

local function AddPiece(set, x1, y1, x2, y2, cls)
    local n = set.n + 1
    set.n = n
    set.x1[n], set.y1[n], set.x2[n], set.y2[n], set.cls[n] = x1, y1, x2, y2, cls
    local sb = set.buckets
    for bx = floor(min(x1, x2) / BUCKET), floor(max(x1, x2) / BUCKET) do
        for by = floor(min(y1, y2) / BUCKET), floor(max(y1, y2) / BUCKET) do
            local k = BucketKey(bx, by)
            local list = sb[k]
            if not list then list = {}; sb[k] = list end
            list[#list + 1] = n
        end
    end
end

-- A newly walked connection a -> b (edge key ek): draw it right away.
local function AddEdge(set, w, ek, a, b)
    if w.edges[ek] ~= 1 or w.edges[b .. ">" .. a] then return end   -- already drawn
    local cls, isFight = ns.ClassifyEdge(w, ek)
    if not ns.InMode(isFight, indexMode) then return end
    local x1, y1 = ns.CellPos(w, a)
    local x2, y2 = ns.CellPos(w, b)
    AddPiece(set, x1, y1, x2, y2, cls)
end

local function Rebuild(inst)
    indexInst, indexMode = inst, PadvinderDB.mapMode
    indexW = PadvinderDB.worlds[inst]
    -- another continent: don't draw the old one's pieces around the player meanwhile
    if live.inst ~= inst then Use(NewSet(inst)) end
    local w, mode = indexW, indexMode
    pending = {}
    buildJob = coroutine.create(function()
        local set = NewSet(inst)
        local seg = w and ns.Segments(inst)
        if seg then
            ns.Polylines(seg,
                function(i) return ns.InMode(seg.fight[i], mode) end,
                function(key) return ns.CellPos(w, key) end,
                SIMPLIFY,
                function(xs, ys, idx, cls)
                    for j = 1, #idx - 1 do
                        local s, e = idx[j], idx[j + 1]
                        AddPiece(set, xs[s], ys[s], xs[e], ys[e], cls)
                    end
                end)
        end
        for _, p in ipairs(pending) do AddEdge(set, p[1], p[2], p[3], p[4]) end
        pending = nil
        Use(set)
    end)
end

-- Called by the recorder after it stored a step a -> b (edge key ek) in world w.
function ns.OnNewEdge(inst, w, ek, a, b)
    if inst ~= indexInst or w ~= indexW then return end   -- a rebuild is coming anyway
    if pending then pending[#pending + 1] = {w, ek, a, b} end
    if live.inst == inst then
        AddEdge(live, w, ek, a, b)
        dirty = true
    end
end

local function Acquire(cls)
    used = used + 1
    local line = lines[used]
    if not line then
        line = overlay:CreateLine(nil, "ARTWORK")
        line:SetThickness(THICKNESS)
        lines[used] = line
    end
    if line.padCls ~= cls then
        line.padCls = cls
        line:SetColorTexture(ns.ClassColor(cls))
    end
    line:Show()
    return line
end

local function AcquireRoute(cls)
    routeUsed = routeUsed + 1
    local line = routeLines[routeUsed]
    if not line then
        line = overlay:CreateLine(nil, "OVERLAY")
        line:SetThickness(ROUTE_THICKNESS)
        routeLines[routeUsed] = line
    end
    if line.padCls ~= cls then
        line.padCls = cls
        line:SetColorTexture(ns.ClassColor(cls))
    end
    line:Show()
    return line
end

local function HideAll()
    for i = 1, used do lines[i]:Hide() end
    for i = 1, routeUsed do routeLines[i]:Hide() end
    used, routeUsed = 0, 0
    lastX = nil
end

-- Clip segment (x1,y1)-(x2,y2) to a circle of radius r around the origin.
-- Returns the visible part, or nil.
local function ClipCircle(x1, y1, x2, y2, r)
    local dx, dy = x2 - x1, y2 - y1
    local r2 = r * r
    local c = x1 * x1 + y1 * y1 - r2
    if c <= 0 and x2 * x2 + y2 * y2 <= r2 then return x1, y1, x2, y2 end
    local a = dx * dx + dy * dy
    if a == 0 then return nil end
    local b = 2 * (x1 * dx + y1 * dy)
    local disc = b * b - 4 * a * c
    if disc <= 0 then return nil end
    disc = sqrt(disc)
    local t0, t1 = (-b - disc) / (2 * a), (-b + disc) / (2 * a)
    if t0 < 0 then t0 = 0 end
    if t1 > 1 then t1 = 1 end
    if t0 >= t1 then return nil end
    return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

-- Clip segment to the square [-r, r] x [-r, r] (Liang-Barsky).
local t0, t1
local function ClipEdge(p, q)   -- one boundary; false = fully outside
    if p == 0 then return q >= 0 end
    local t = q / p
    if p < 0 then
        if t > t1 then return false end
        if t > t0 then t0 = t end
    else
        if t < t0 then return false end
        if t < t1 then t1 = t end
    end
    return true
end
local function ClipSquare(x1, y1, x2, y2, r)
    local dx, dy = x2 - x1, y2 - y1
    t0, t1 = 0, 1
    if ClipEdge(-dx, x1 + r) and ClipEdge(dx, r - x1) and ClipEdge(-dy, y1 + r) and ClipEdge(dy, r - y1)
        and t0 < t1 then
        return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
    end
    return nil
end

local function DrawLine(cls, x1, y1, x2, y2)
    local line
    if cls == "route" or cls == "routeAir" or cls == "routeGuess" then
        line = AcquireRoute(cls)
    else
        if used >= MAX_LINES then return end
        line = Acquire(cls)
    end
    line:SetStartPoint("CENTER", overlay, x1, y1)
    line:SetEndPoint("CENTER", overlay, x2, y2)
end

-- Draw a segment, leaving out the part within radius r of the centre: the player arrow is
-- part of the minimap itself, so addon lines always cover it. A hole keeps it visible.
local function DrawWithHole(cls, x1, y1, x2, y2, r)
    local dx, dy = x2 - x1, y2 - y1
    local a = dx * dx + dy * dy
    local c = x1 * x1 + y1 * y1 - r * r
    local b = 2 * (x1 * dx + y1 * dy)
    local disc = b * b - 4 * a * c
    if a == 0 or disc <= 0 then
        if c > 0 then DrawLine(cls, x1, y1, x2, y2) end
        return
    end
    disc = sqrt(disc)
    local h0, h1 = (-b - disc) / (2 * a), (-b + disc) / (2 * a)
    if h1 <= 0 or h0 >= 1 then
        DrawLine(cls, x1, y1, x2, y2)
        return
    end
    if h0 > 0 then DrawLine(cls, x1, y1, x1 + h0 * dx, y1 + h0 * dy) end
    if h1 < 1 then DrawLine(cls, x1 + h1 * dx, y1 + h1 * dy, x2, y2) end
end

local function Draw(x, y, inst, radius, halfWidth, facing, square)
    used, routeUsed = 0, 0
    drawId = drawId + 1
    local scale = halfWidth / radius             -- minimap units per yard
    local clipR = halfWidth * EDGE
    local Clip = square and ClipSquare or ClipCircle
    local rotate = facing ~= 0
    local fs, fc = sin(facing), cos(facing)
    local function Screen(wx, wy)   -- same maths as HereBeDragons-Pins
        local ax, ay = x - wx, y - wy
        if rotate then ax, ay = ax * fc - ay * fs, ax * fs + ay * fc end
        return ax * scale, -ay * scale
    end

    -- buckets that can hold visible pieces (corners of a square map reach radius * sqrt 2)
    local reach = radius * (square and 1.42 or 1)
    for bx = floor((x - reach) / BUCKET), floor((x + reach) / BUCKET) do
        for by = floor((y - reach) / BUCKET), floor((y + reach) / BUCKET) do
            local list = buckets[BucketKey(bx, by)]
            if list then
                for k = 1, #list do
                    local i = list[k]
                    if stamp[i] ~= drawId then   -- long pieces sit in several buckets
                        stamp[i] = drawId
                        -- same maths as HereBeDragons-Pins: offset from the player, rotated
                        -- with the minimap, x to the right, y up
                        local ax, ay = x - px1[i], y - py1[i]
                        local bx2, by2 = x - px2[i], y - py2[i]
                        if rotate then
                            ax, ay = ax * fc - ay * fs, ax * fs + ay * fc
                            bx2, by2 = bx2 * fc - by2 * fs, bx2 * fs + by2 * fc
                        end
                        local sx1, sy1, sx2, sy2 = Clip(ax * scale, -ay * scale, bx2 * scale, -by2 * scale, clipR)
                        if sx1 then DrawWithHole(pcls[i], sx1, sy1, sx2, sy2, HOLE) end
                    end
                end
            end
        end
    end
    for i = used + 1, #lines do lines[i]:Hide() end
    ns.lastMinimapLineCount = used

    -- the planned route (walking cyan, flights and boats gold), from the player's spot onwards
    local route = ns.route
    if route and route.legs then
        for li, leg in ipairs(route.legs) do
            if leg.inst == inst then
                local rx, ry, sure = leg.x, leg.y, leg.sure
                for i = (li == 1 and ns.RouteStart and ns.RouteStart() or 1), #rx - 1 do
                    local ax, ay = Screen(rx[i], ry[i])
                    local bx, by = Screen(rx[i + 1], ry[i + 1])
                    local sx1, sy1, sx2, sy2 = Clip(ax, ay, bx, by, clipR)
                    if sx1 then
                        if leg.kind ~= "walk" then
                            DrawWithHole("routeAir", sx1, sy1, sx2, sy2, HOLE)
                        elseif sure and sure[i] then
                            DrawWithHole("route", sx1, sy1, sx2, sy2, HOLE)
                        else
                            ns.Dashes(sx1, sy1, sx2, sy2, DASH, GAP, function(a, b, c, d)
                                DrawWithHole("routeGuess", a, b, c, d, HOLE)
                            end)
                        end
                    end
                end
            end
        end
    end
    for i = routeUsed + 1, #routeLines do routeLines[i]:Hide() end
    drawnRouteRev = ns.routeRev
end

local function ViewRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        local r = C_Minimap.GetViewRadius()
        if r and r > 0 then return r end
    end
    local sizes = (IsIndoors and IsIndoors()) and MINIMAP_SIZE.indoor or MINIMAP_SIZE.outdoor
    return (sizes[Minimap:GetZoom()] or sizes[0]) / 2
end

local function OnUpdate(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < 1 / UPDATE_RATE then return end
    sinceUpdate = 0

    if not PadvinderDB.showMinimap or IsInInstance() then
        if used + routeUsed > 0 then HideAll() end
        return
    end
    local x, y, inst, hidden = ns.PlayerPos()
    if not x then
        if not hidden and used + routeUsed > 0 then HideAll() end   -- (hidden: keep the picture)
        return
    end

    if inst ~= indexInst or PadvinderDB.mapMode ~= indexMode or PadvinderDB.worlds[inst] ~= indexW then
        Rebuild(inst)
    end
    if buildJob then
        ns.SliceStart()
        local ok, err = coroutine.resume(buildJob)
        if not ok then
            buildJob, pending = nil, nil
            ns.Print("minimap paths failed: " .. tostring(err))
        elseif coroutine.status(buildJob) == "dead" then
            buildJob = nil
        end
    end

    local facing = 0
    if GetCVar("rotateMinimap") == "1" then
        facing = ns.Facing()
        if not facing then return end   -- hidden for a moment: keep the picture
    end
    local radius = ViewRadius()
    local halfWidth = Minimap:GetWidth() / 2
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE" or false

    -- skip when nothing visible changed
    if ns.routeRev ~= drawnRouteRev then dirty = true end
    if not dirty and lastX and radius == lastRadius and halfWidth == lastWidth
        and square == lastSquare and abs(facing - lastFacing) < 0.005 then
        local dx, dy = x - lastX, y - lastY
        if sqrt(dx * dx + dy * dy) * halfWidth / radius < MOVE_PIXELS then return end
    end
    lastX, lastY, lastFacing, lastRadius, lastWidth, lastSquare = x, y, facing, radius, halfWidth, square
    dirty = false

    Draw(x, y, inst, radius, halfWidth, facing, square)
end

-- Rebuild and redraw on the next update (e.g. after turning minimap paths on).
function ns.RefreshMinimap()
    indexInst = nil
end

function ns.InitMinimap()
    if overlay or not Minimap then return end
    overlay = CreateFrame("Frame", nil, Minimap)
    overlay:SetAllPoints(Minimap)
    -- above the minimap itself, below the addon pins (TomTom, Questie) and the border
    overlay:SetFrameLevel(Minimap:GetFrameLevel() + 1)
    -- OnUpdate stops by itself while the minimap is hidden
    overlay:SetScript("OnUpdate", OnUpdate)
end
