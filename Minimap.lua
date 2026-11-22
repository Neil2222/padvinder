-- Draws the recorded paths on the minimap, around the player, in the same colours as the
-- world map. Follows minimap zoom, indoor/outdoor scale and "rotate minimap". Lines are
-- clipped at the minimap's edge (round, or square when an addon makes the minimap square).
--
-- Performance: segments are put in a spatial index (BUCKET-yard squares), so each update only
-- looks at the ones near the player. Lines are only moved when the picture actually changes
-- (moved half a pixel, turned, zoomed), at most UPDATE_RATE times a second.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2          -- line width in minimap units (~pixels)
local MAX_LINES = 3000
local BUCKET = 64            -- spatial index square size in yards
local REBUILD_INTERVAL = 3   -- seconds: pick up newly walked paths at most this often
local UPDATE_RATE = 30       -- max redraws per second
local MOVE_PIXELS = 0.5      -- redraw when the player moved this many minimap pixels
local EDGE = 0.95            -- clip at this fraction of the radius, just inside the border

-- Diameter of the minimap in yards per zoom level, for clients without C_Minimap.GetViewRadius.
local MINIMAP_SIZE = {
    indoor  = {[0] = 300, 240, 180, 120, 80, 50},
    outdoor = {[0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3},
}

local floor, sqrt, sin, cos, abs, huge = math.floor, math.sqrt, math.sin, math.cos, math.abs, math.huge

local overlay
local lines, used = {}, 0

-- Spatial index: buckets[key] = {segment indices}
local index, indexSeg, indexInst, indexMode, indexRev
local sinceRebuild, sinceUpdate = 0, 0
local lastX, lastY, lastFacing, lastRadius, lastWidth, lastSquare, drawnIndex

local function BucketKey(bx, by)
    return (bx + 50000) * 100000 + (by + 50000)
end

local function Rebuild(inst)
    sinceRebuild = 0
    indexInst, indexMode, indexRev = inst, PadvinderDB.mapMode, ns.rev
    index = {}
    indexSeg = ns.Segments(inst)
    local seg = indexSeg
    if not seg then return end
    local mode = indexMode
    for i = 1, seg.n do
        if ns.InMode(seg.fight[i], mode) then
            local k = BucketKey(floor((seg.x1[i] + seg.x2[i]) / 2 / BUCKET),
                floor((seg.y1[i] + seg.y2[i]) / 2 / BUCKET))
            local list = index[k]
            if not list then list = {}; index[k] = list end
            list[#list + 1] = i
        end
    end
end

local function Acquire()
    used = used + 1
    local line = lines[used]
    if not line then
        line = overlay:CreateLine(nil, "ARTWORK")
        lines[used] = line
    end
    line:Show()
    return line
end

local function HideAll()
    for i = 1, used do lines[i]:Hide() end
    used = 0
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
local function ClipEdge(p, q)   -- one Liang-Barsky boundary; false = fully outside
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

local function Draw(x, y, radius, halfWidth, facing, square)
    used = 0
    local seg = indexSeg
    local scale = halfWidth / radius             -- minimap units per yard
    local clipR = halfWidth * EDGE
    local Clip = square and ClipSquare or ClipCircle
    local rotate = facing ~= 0
    local fs, fc = sin(facing), cos(facing)

    -- buckets that can hold visible segments (corners of a square map reach radius * sqrt 2)
    local reach = radius * (square and 1.42 or 1) + BUCKET
    local bx0, bx1 = floor((x - reach) / BUCKET), floor((x + reach) / BUCKET)
    local by0, by1 = floor((y - reach) / BUCKET), floor((y + reach) / BUCKET)

    local xs1, ys1, xs2, ys2, cls = seg.x1, seg.y1, seg.x2, seg.y2, seg.cls
    for bx = bx0, bx1 do
        for by = by0, by1 do
            local list = index[BucketKey(bx, by)]
            if list then
                for k = 1, #list do
                    local i = list[k]
                    -- same maths as HereBeDragons-Pins: offset from the player, rotated with
                    -- the minimap, x to the right, y up
                    local ax, ay = x - xs1[i], y - ys1[i]
                    local bx2, by2 = x - xs2[i], y - ys2[i]
                    if rotate then
                        ax, ay = ax * fc - ay * fs, ax * fs + ay * fc
                        bx2, by2 = bx2 * fc - by2 * fs, bx2 * fs + by2 * fc
                    end
                    local sx1, sy1, sx2, sy2 = Clip(ax * scale, -ay * scale, bx2 * scale, -by2 * scale, clipR)
                    if sx1 and used < MAX_LINES then
                        local line = Acquire()
                        line:SetStartPoint("CENTER", overlay, sx1, sy1)
                        line:SetEndPoint("CENTER", overlay, sx2, sy2)
                        line:SetThickness(THICKNESS)
                        line:SetColorTexture(ns.ClassColor(cls[i]))
                    end
                end
            end
        end
    end
    for i = used + 1, #lines do lines[i]:Hide() end
    ns.lastMinimapLineCount = used
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
    sinceRebuild = sinceRebuild + elapsed
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < 1 / UPDATE_RATE then return end
    sinceUpdate = 0

    if not PadvinderDB.showMinimap or IsInInstance() then
        if used > 0 then HideAll() end
        return
    end
    local x, y, inst = HBD:GetPlayerWorldPosition()
    if not x or not y or not inst or (issecretvalue and (issecretvalue(x) or issecretvalue(y))) then
        if used > 0 then HideAll() end
        return
    end

    if inst ~= indexInst or PadvinderDB.mapMode ~= indexMode
        or (indexRev ~= ns.rev and sinceRebuild >= REBUILD_INTERVAL) then
        Rebuild(inst)
    end
    if not indexSeg then
        if used > 0 then HideAll() end
        return
    end

    local facing = 0
    if GetCVar("rotateMinimap") == "1" then
        facing = GetPlayerFacing()
        if not facing then
            if used > 0 then HideAll() end
            return
        end
    end
    local radius = ViewRadius()
    local halfWidth = Minimap:GetWidth() / 2
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE" or false

    -- skip when nothing visible changed
    if lastX and drawnIndex == index and radius == lastRadius and halfWidth == lastWidth
        and square == lastSquare and abs(facing - lastFacing) < 0.005 then
        local dx, dy = x - lastX, y - lastY
        if sqrt(dx * dx + dy * dy) * halfWidth / radius < MOVE_PIXELS then return end
    end
    lastX, lastY, lastFacing, lastRadius, lastWidth, lastSquare, drawnIndex =
        x, y, facing, radius, halfWidth, square, index

    Draw(x, y, radius, halfWidth, facing, square)
end

-- Force a redraw on the next update (e.g. after turning minimap paths on).
function ns.RefreshMinimap()
    indexInst = nil
    lastX = nil
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
