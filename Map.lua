-- Tekent de opgenomen paden als heatmap op de wereldkaart.
-- Geel = weinig gelopen, oranje/rood = vaak gelopen, blauw = alleen naar beneden gevallen.

local ADDON, ns = ...
local HBD = LibStub("HereBeDragons-2.0")

local THICKNESS = 2.5     -- lijndikte in schermpixels (gecorrigeerd voor inzoomen)
local MAX_LINES = 15000
local FRAME_LEVEL = 2010  -- net onder de iconen van Questie (2015+)
local REDRAW_INTERVAL = 2 -- seconden: nieuwe data bij open kaart hooguit zo vaak hertekenen

local log, min = math.log, math.min

local overlay
local lines, used = {}, 0
local shownMap, shownW, shownH, shownScale, shownRev
local sinceDraw = 0

-- Gesplitste edge-sleutels cachen
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

local function Acquire()
    used = used + 1
    local line = lines[used]
    if not line then
        line = overlay:CreateLine(nil, "OVERLAY")
        lines[used] = line
    end
    line:Show()
    return line
end

local function HeatColor(count)
    -- 1 keer = geel, ~12+ keer = rood
    local t = min(1, log(count) / log(12))
    return 1, 0.95 - 0.7 * t, 0.2 - 0.1 * t, 0.55 + 0.4 * t
end

local function Redraw()
    used = 0
    local mapID = WorldMapFrame:GetMapID()
    local data = mapID and HBD.mapData[mapID]
    local canvas = WorldMapFrame:GetCanvas()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local scale = WorldMapFrame.ScrollContainer:GetCanvasScale()
    shownMap, shownW, shownH, shownScale, shownRev = mapID, width, height, scale, ns.rev
    sinceDraw = 0

    if PadvinderDB.showMap and data and data[1] ~= 0 and data[2] ~= 0 and width > 0 then
        local zw, zh, left, top = data[1], data[2], data[3], data[4]
        local w = PadvinderDB.worlds[data.instance]
        if w then
            local edges, drops = w.edges, w.drops
            local thick = THICKNESS / scale
            for ek, count in pairs(edges) do
                local a, b = Split(ek)
                local reverse = edges[b .. ">" .. a]
                -- elke verbinding één keer tekenen, ook als hij in beide richtingen gelopen is
                if not reverse or a < b then
                    local ax, ay = ns.CellCenter(a)
                    local bx, by = ns.CellCenter(b)
                    local x1, y1 = (left - ax) / zw, (top - ay) / zh
                    local x2, y2 = (left - bx) / zw, (top - by) / zh
                    if (x1 > -0.02 and x1 < 1.02 and y1 > -0.02 and y1 < 1.02)
                        or (x2 > -0.02 and x2 < 1.02 and y2 > -0.02 and y2 < 1.02) then
                        if used >= MAX_LINES then break end
                        local line = Acquire()
                        line:SetStartPoint("TOPLEFT", overlay, x1 * width, -y1 * height)
                        line:SetEndPoint("TOPLEFT", overlay, x2 * width, -y2 * height)
                        line:SetThickness(thick)
                        if drops[ek] and not reverse then
                            line:SetColorTexture(0.4, 0.7, 1, 0.8)
                        else
                            line:SetColorTexture(HeatColor(count + (reverse or 0)))
                        end
                    end
                end
            end
        end
    end

    for i = used + 1, #lines do
        lines[i]:Hide()
    end
end

local function Restyle(scale)
    shownScale = scale
    local thick = THICKNESS / scale
    for i = 1, used do
        lines[i]:SetThickness(thick)
    end
end

local function OnUpdate(_, elapsed)
    sinceDraw = sinceDraw + elapsed
    local canvas = WorldMapFrame:GetCanvas()
    local mapID = WorldMapFrame:GetMapID()
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local scale = WorldMapFrame.ScrollContainer:GetCanvasScale()
    if mapID ~= shownMap or width ~= shownW or height ~= shownH then
        Redraw()
    elseif shownRev ~= ns.rev and sinceDraw >= REDRAW_INTERVAL then
        Redraw()
    elseif scale ~= shownScale then
        Restyle(scale)
    end
end

function ns.InitMap()
    if overlay or not WorldMapFrame then return end
    local canvas = WorldMapFrame:GetCanvas()
    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(FRAME_LEVEL)
    -- OnUpdate draait alleen zolang de kaart open is
    overlay:SetScript("OnUpdate", OnUpdate)
    overlay:SetScript("OnShow", function() shownMap = nil end)
end
