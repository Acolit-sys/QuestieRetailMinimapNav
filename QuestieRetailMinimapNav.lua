local QRN = CreateFrame("Frame", "QuestieRetailNav", UIParent)

local arrow
local target -- { x, y, instance, distance, name }

local targetTimer = 0
local arrowTimer = 0
local tooltipTimer = 0

-- Timestamp of the last time we got a valid player world
-- position. Used to briefly freeze the arrow during zone
-- transitions instead of flickering it off.
local lastValidTime = 0

local TARGET_INTERVAL = 0.5
local ARROW_INTERVAL = 0.05
local TOOLTIP_INTERVAL = 0.1

-- How long (seconds) to keep the arrow frozen/shown when the
-- player position briefly becomes unavailable (zone change).
local POSITION_GRACE = 1.0

-- When the player is this close to the objective (in yards) the arrow is
-- hidden instead of jittering around the minimap.
local ARRIVAL_DISTANCE = 15

-- Upper bound on how far an "area" radius can push the hide threshold.
-- Scattered spawns (e.g. mobs spread across a whole zone) would otherwise
-- produce an enormous radius and hide the arrow everywhere.
local MAX_AREA_RADIUS = 100

------------------------------------------------------------
-- Tunable arrow placement.
--
-- Tune these LIVE in-game with the /qrn slash command, then
-- your values persist (SavedVariables). Values below are the
-- defaults.
--
--   radiusScale : how far from the minimap center the arrow
--                 center sits. 1.0 = on the edge, 0.5 = halfway.
--   size        : arrow width/height in pixels.
------------------------------------------------------------

local defaults = {
    radiusScale = 0.75,
    size = 64,
}

local DB = {}

for k, v in pairs(defaults) do
    DB[k] = v
end

------------------------------------------------------------
-- Apply the arrow size to the live frame (used after /qrn size).
------------------------------------------------------------

local function ApplyArrowConfig()

    if arrow then
        arrow:SetWidth(DB.size)
        arrow:SetHeight(DB.size)
    end
end

------------------------------------------------------------
-- Slash command for live tuning:
--   /qrn                 -> show current values
--   /qrn radius <n>      -> set radiusScale (e.g. /qrn radius 0.8)
--   /qrn size <n>        -> set arrow size (e.g. /qrn size 64)
--   /qrn reset           -> restore defaults
------------------------------------------------------------

SLASH_QRNNAV1 = "/qrn"

SlashCmdList["QRNNAV"] = function(msg)

    msg = (msg or ""):lower()
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "" then

        print(
            "|cffffd100QuestieNav|r radiusScale="
                .. tostring(DB.radiusScale)
                .. " size="
                .. tostring(DB.size)
        )

    elseif msg == "reset" then

        DB.radiusScale = defaults.radiusScale
        DB.size = defaults.size
        QRNNavDB = DB
        ApplyArrowConfig()
        print("|cffffd100QuestieNav|r reset to defaults.")

    else

        local cmd, val = msg:match("^(%S+)%s+(%S+)$")

        if (cmd == "radius" or cmd == "r") and tonumber(val) then

            DB.radiusScale = tonumber(val)
            QRNNavDB = DB
            print(
                "|cffffd100QuestieNav|r radiusScale = "
                    .. tostring(DB.radiusScale)
            )

        elseif (cmd == "size" or cmd == "s") and tonumber(val) then

            DB.size = tonumber(val)
            QRNNavDB = DB
            ApplyArrowConfig()
            print(
                "|cffffd100QuestieNav|r size = "
                    .. tostring(DB.size)
            )

        else

            print(
                "|cffffd100QuestieNav|r usage: /qrn "
                    .. "[radius <n> | size <n> | reset]"
            )
        end
    end
end

------------------------------------------------------------
-- Distance -> color gradient (TomTom style)
--
-- Red when far, yellow in the middle, green when close.
-- The arrow texture must be white so SetVertexColor tints it
-- cleanly.
------------------------------------------------------------

local COLOR_GOOD = { 0, 1, 0 }   -- green  (near the objective)
local COLOR_MID  = { 1, 1, 0 }   -- yellow (halfway)
local COLOR_BAD  = { 1, 0, 0 }   -- red    (far away)

local COLOR_NEAR = 30    -- <= this many yards = fully green
local COLOR_FAR  = 250   -- >= this many yards = fully red

local function GetArrowColor(distance)

    ----------------------------------------------------
    -- perc: 0 = far (red), 1 = near (green)
    ----------------------------------------------------

    local perc

    if distance <= COLOR_NEAR then
        perc = 1
    elseif distance >= COLOR_FAR then
        perc = 0
    else
        perc = (COLOR_FAR - distance) / (COLOR_FAR - COLOR_NEAR)
    end


    local r
    local g
    local b

    if perc >= 0.5 then

        ----------------------------------------------------
        -- yellow -> green
        ----------------------------------------------------

        local t = (perc - 0.5) * 2

        r = COLOR_MID[1] + (COLOR_GOOD[1] - COLOR_MID[1]) * t
        g = COLOR_MID[2] + (COLOR_GOOD[2] - COLOR_MID[2]) * t
        b = COLOR_MID[3] + (COLOR_GOOD[3] - COLOR_MID[3]) * t

    else

        ----------------------------------------------------
        -- red -> yellow
        ----------------------------------------------------

        local t = perc * 2

        r = COLOR_BAD[1] + (COLOR_MID[1] - COLOR_BAD[1]) * t
        g = COLOR_BAD[2] + (COLOR_MID[2] - COLOR_BAD[2]) * t
        b = COLOR_BAD[3] + (COLOR_MID[3] - COLOR_BAD[3]) * t
    end

    return r, g, b
end

------------------------------------------------------------
-- Cached Questie modules.
--
-- Imported lazily so we never race Questie's own load.
------------------------------------------------------------

local QuestieMap
local ZoneDB
local TrackerUtils
local Phasing
local HBD

local function ImportModules()

    if not QuestieLoader then
        return false
    end

    if QuestieMap and ZoneDB and TrackerUtils and Phasing and HBD then
        return true
    end

    QuestieMap =
        QuestieLoader:ImportModule(
            "QuestieMap"
        )

    ZoneDB =
        QuestieLoader:ImportModule(
            "ZoneDB"
        )

    TrackerUtils =
        QuestieLoader:ImportModule(
            "TrackerUtils"
        )

    Phasing =
        QuestieLoader:ImportModule(
            "Phasing"
        )

    if QuestieCompat and QuestieCompat.HBD then
        HBD = QuestieCompat.HBD
    elseif LibStub then
        HBD = LibStub("HereBeDragonsQuestie-2.0")
    end

    return QuestieMap ~= nil
        and ZoneDB ~= nil
        and TrackerUtils ~= nil
        and Phasing ~= nil
        and HBD ~= nil
end

------------------------------------------------------------
-- CREATE ARROW
------------------------------------------------------------

local function CreateArrow()

    if arrow then
        return
    end

    --------------------------------------------------------
    -- IMPORTANT:
    -- parent is UIParent, NOT Minimap.
    --
    -- DragonUI can change Minimap's frame hierarchy/clipping.
    -- We position our arrow relative to Minimap but keep it
    -- outside Minimap's clipping region.
    --------------------------------------------------------

    arrow = CreateFrame(
        "Frame",
        "QuestieRetailNavArrow",
        UIParent
    )

    arrow:SetWidth(DB.size)
    arrow:SetHeight(DB.size)

    --------------------------------------------------------
    -- "TOOLTIP" strata keeps the arrow ABOVE the minimap
    -- (MEDIUM) and its DragonUI decorations. We give the arrow
    -- a LOW frame level so GameTooltip renders above it.
    --
    -- The arrow stays mouse-TRANSPARENT (no EnableMouse), so
    -- native minimap tooltips (town names, POI markers) are
    -- NOT blocked and can be merged with ours. Hover is
    -- detected in OnUpdate via arrow:IsMouseOver().
    --------------------------------------------------------

    arrow:SetFrameStrata("TOOLTIP")
    arrow:SetFrameLevel(0)

    --------------------------------------------------------
    -- Keep GameTooltip ABOVE the arrow. Native tooltips reset
    -- their own frame level when they re-anchor, so we re-raise
    -- it on EVERY show via a hook (a one-time SetFrameLevel was
    -- not enough).
    --------------------------------------------------------

    if GameTooltip then

        GameTooltip:HookScript(
            "OnShow",
            function()
                GameTooltip:SetFrameLevel(
                    arrow:GetFrameLevel() + 10
                )
            end
        )
    end

    --------------------------------------------------------
    -- BODY layer (tintable).
    -- Grayscale from the original arrow's red channel, so it
    -- keeps full shading contrast and gets tinted by the
    -- distance gradient (red far -> green near).
    --------------------------------------------------------

    arrow.texture =
        arrow:CreateTexture(
            nil,
            "ARTWORK"
        )

    arrow.texture:SetTexture(
        "Interface\\AddOns\\QuestieRetailMinimapNav\\arrow_body.tga"
    )

    arrow.texture:SetAllPoints()
    arrow.texture:SetTexCoord(0, 1, 0, 1)

    arrow.texture:SetVertexColor(
        1.0,
        1.0,
        1.0,
        1.0
    )


    --------------------------------------------------------
    -- GLOSS layer (always white).
    -- The highlight mask extracted from the original's G/B
    -- channels. It is NOT tinted, so the artist's white
    -- highlights stay white regardless of the body tint.
    --------------------------------------------------------

    arrow.gloss =
        arrow:CreateTexture(
            nil,
            "OVERLAY"
        )

    arrow.gloss:SetTexture(
        "Interface\\AddOns\\QuestieRetailMinimapNav\\arrow_gloss.tga"
    )

    arrow.gloss:SetAllPoints()
    arrow.gloss:SetTexCoord(0, 1, 0, 1)

    arrow.gloss:SetVertexColor(
        1.0,
        1.0,
        1.0,
        1.0
    )


    --------------------------------------------------------
    -- SEPARATE quest-name tooltip frame.
    --
    -- We do NOT use GameTooltip for the standalone case,
    -- because the minimap's native SetMinimapMouseover() re-owns
    -- GameTooltip every frame while the cursor is over the
    -- (mouse-transparent) arrow, wiping our text. Our own frame
    -- is immune to that, so the standalone tooltip is reliable.
    --------------------------------------------------------

    arrow.questTooltip =
        CreateFrame("Frame", nil, UIParent)

    arrow.questTooltip:SetFrameStrata("TOOLTIP")
    arrow.questTooltip:SetFrameLevel(100)
    arrow.questTooltip:SetClampedToScreen(true)

    local backdrop = GameTooltip and GameTooltip:GetBackdrop()

    if not backdrop then
        backdrop = {
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        }
    end

    arrow.questTooltip:SetBackdrop(backdrop)

    if GameTooltip then

        local r, g, b, a = GameTooltip:GetBackdropColor()

        if r then
            arrow.questTooltip:SetBackdropColor(r, g, b, a)
        end

        r, g, b, a = GameTooltip:GetBackdropBorderColor()

        if r then
            arrow.questTooltip:SetBackdropBorderColor(r, g, b, a)
        end
    end

    arrow.questTooltip.text =
        arrow.questTooltip:CreateFontString(
            nil,
            "OVERLAY"
        )

    --------------------------------------------------------
    -- Match the font of the native tooltip title (which is
    -- what single-line minimap tooltips use), so our text is
    -- the same size as the other tooltips.
    --------------------------------------------------------

    if GameTooltipHeaderText then

        local font, size, flags = GameTooltipHeaderText:GetFont()

        if font then
            arrow.questTooltip.text:SetFont(font, size, flags)
        elseif GameTooltipHeaderText:GetFontObject() then
            arrow.questTooltip.text:SetFontObject(
                GameTooltipHeaderText:GetFontObject()
            )
        else
            arrow.questTooltip.text:SetFontObject("GameFontNormal")
        end

    else

        arrow.questTooltip.text:SetFontObject("GameFontNormal")
    end

    arrow.questTooltip.text:SetPoint("TOPLEFT", 10, -8)
    arrow.questTooltip.text:SetJustifyH("LEFT")

    arrow.questTooltip:Hide()


    arrow:Hide()
end


------------------------------------------------------------
-- FIND NEAREST OBJECTIVE
--
-- For a single-point objective (one NPC/mob/object) the
-- nearest spawn is a stable point. For an "area" objective
-- (many spawns spread over a region) the nearest individual
-- spawn changes as the player moves, which makes the arrow
-- spin. To avoid that we navigate toward the CENTER of the
-- objective's spawns (their average), which is stable.
------------------------------------------------------------

------------------------------------------------------------
-- Returns the world-space centroid (average) of every
-- visible spawn of an objective, limited to the player's
-- current instance. Falls back to a single nearest spawn
-- when no average can be produced (e.g. dungeon objectives).
------------------------------------------------------------

local function GetObjectiveCenter(objective, playerInstance)

    if not objective or not objective.spawnList then
        return nil
    end

    ----------------------------------------------------
    -- Collect every visible spawn (same instance) as a
    -- flat {x1, y1, x2, y2, ...} list.
    ----------------------------------------------------

    local points = {}
    local sumX = 0
    local sumY = 0

    for _, spawnData in pairs(objective.spawnList) do

        local spawnsByZone = spawnData and spawnData.Spawns

        if spawnsByZone then

            for zone, spawns in pairs(spawnsByZone) do

                if spawns then

                    for _, spawn in ipairs(spawns) do

                        ----------------------------------------------------
                        -- Skip dungeon-only spawns (-1 coords); those are
                        -- resolved to the dungeon entrance separately.
                        ----------------------------------------------------

                        if spawn
                            and spawn[1] ~= -1
                            and spawn[2] ~= -1
                            and Phasing.IsSpawnDataVisible(spawn)
                        then

                            local uiMapId =
                                ZoneDB:GetUiMapIdByAreaId(zone)

                            if uiMapId then

                                local x
                                local y
                                local instance

                                x,
                                y,
                                instance =
                                    HBD:GetWorldCoordinatesFromZone(
                                        spawn[1] / 100,
                                        spawn[2] / 100,
                                        uiMapId
                                    )

                                if x
                                    and y
                                    and instance == playerInstance
                                then

                                    points[#points + 1] = x
                                    points[#points + 1] = y
                                    sumX = sumX + x
                                    sumY = sumY + y
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local count = #points / 2

    if count == 0 then
        return nil
    end


    local cx = sumX / count
    local cy = sumY / count


    ----------------------------------------------------
    -- radius = max distance from the centroid to any
    -- spawn. It represents the extent of the objective's
    -- area; the arrow hides once the player is inside it.
    ----------------------------------------------------

    local radius = 0

    for i = 1, #points, 2 do

        local dx = points[i] - cx
        local dy = points[i + 1] - cy
        local d =
            math.sqrt(
                dx * dx + dy * dy
            )

        if d > radius then
            radius = d
        end
    end

    return cx, cy, playerInstance, radius
end


local function FindNearestObjective()

    if not ImportModules() then
        return nil
    end

    local questIds
    local questDetails

    questIds,
    questDetails =
        TrackerUtils:GetSortedQuestIds()

    if not questIds or not questDetails then
        return nil
    end


    local playerX
    local playerY
    local playerInstance

    playerX,
    playerY,
    playerInstance =
        HBD:GetPlayerWorldPosition()

    if not playerX or not playerY then
        return nil
    end


    local best


    ----------------------------------------------------
    -- Helper: remember the nearest of (x, y) candidates.
    ----------------------------------------------------

    local function consider(x, y, instance, name, radius)

        if not x or not y or not instance then
            return
        end

        if instance ~= playerInstance then
            return
        end

        local distance =
            math.sqrt(
                (x - playerX) ^ 2
                + (y - playerY) ^ 2
            )

        if not best or distance < best.distance then

            best = {
                x = x,
                y = y,
                instance = instance,
                distance = distance,
                name = name,
                radius = radius or 0
            }
        end
    end


    for _, questId in ipairs(questIds) do

        local details =
            questDetails[questId]

        local quest =
            details and details.quest

        if quest then

            local complete = quest:IsComplete()

            ----------------------------------------------------
            -- IsComplete():
            --   1 = complete (navigate to turn-in / finisher)
            --   0 = incomplete (navigate to objective)
            --  -1 = failed (skip)
            ----------------------------------------------------

            if complete == 1 then

                local spawn
                local zone
                local name

                spawn,
                zone,
                name =
                    QuestieMap:GetNearestQuestSpawn(
                        quest
                    )

                if spawn and zone and spawn[1] and spawn[2] then

                    local uiMapId =
                        ZoneDB:GetUiMapIdByAreaId(zone)

                    if uiMapId then

                        local x
                        local y
                        local instance

                        x,
                        y,
                        instance =
                            HBD:GetWorldCoordinatesFromZone(
                                spawn[1] / 100,
                                spawn[2] / 100,
                                uiMapId
                            )

                        consider(x, y, instance, quest.name, 0)
                    end
                end

            elseif complete ~= -1 then

                local allObjectives = {}

                for _, objective in pairs(quest.Objectives or {}) do
                    allObjectives[#allObjectives + 1] = objective
                end

                for _, objective in pairs(quest.SpecialObjectives or {}) do
                    allObjectives[#allObjectives + 1] = objective
                end

                for _, objective in ipairs(allObjectives) do

                    ----------------------------------------------------
                    -- Skip objectives that are already fulfilled.
                    ----------------------------------------------------

                    if objective
                        and ((not objective.Needed)
                            or objective.Needed ~= objective.Collected)
                    then

                        local x
                        local y
                        local instance
                        local radius

                        x,
                        y,
                        instance,
                        radius =
                            GetObjectiveCenter(
                                objective,
                                playerInstance
                            )

                        if x and y then

                            consider(
                                x,
                                y,
                                instance,
                                quest.name,
                                radius
                            )

                        else

                            ----------------------------------------------------
                            -- Fallback: a single nearest spawn (handles
                            -- dungeon objectives / entrances).
                            ----------------------------------------------------

                            local spawn
                            local zone
                            local name

                            spawn,
                            zone,
                            name =
                                QuestieMap:GetNearestSpawn(
                                    objective
                                )

                            if spawn
                                and zone
                                and spawn[1]
                                and spawn[2]
                            then

                                local uiMapId =
                                    ZoneDB:GetUiMapIdByAreaId(zone)

                                if uiMapId then

                                    x,
                                    y,
                                    instance =
                                        HBD:GetWorldCoordinatesFromZone(
                                            spawn[1] / 100,
                                            spawn[2] / 100,
                                            uiMapId
                                        )

                                    consider(
                                        x,
                                        y,
                                        instance,
                                        quest.name,
                                        0
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end


------------------------------------------------------------
-- UPDATE TARGET
------------------------------------------------------------

local function UpdateTarget()

    target =
        FindNearestObjective()
end


------------------------------------------------------------
-- UPDATE ARROW
--
-- The math below mirrors Questie's own minimap pin math
-- (Compat/HBD.lua), so the arrow stays correct with rotating
-- minimaps and different zoom levels.
------------------------------------------------------------

local function UpdateArrow()

    if not arrow then
        return
    end

    if not target then
        arrow:Hide()
        return
    end

    if not HBD then
        arrow:Hide()
        return
    end


    --------------------------------------------------------
    -- Hide while the minimap itself is hidden (world map open,
    -- in a battleground, etc.).
    --------------------------------------------------------

    if not Minimap or not Minimap:IsShown() then
        arrow:Hide()
        return
    end


    local playerX
    local playerY
    local playerInstance

    playerX,
    playerY,
    playerInstance =
        HBD:GetPlayerWorldPosition()

    if not playerX or not playerY then

        ----------------------------------------------------
        -- Position briefly unavailable (zone transition):
        -- keep the arrow where it was for a short grace
        -- period instead of flickering it off.
        ----------------------------------------------------

        if arrow:IsShown()
            and GetTime() - lastValidTime < POSITION_GRACE
        then
            return
        end

        arrow:Hide()
        return
    end

    lastValidTime = GetTime()

    if target.instance ~= playerInstance then
        arrow:Hide()
        return
    end


    --------------------------------------------------------
    -- World delta: player - target (same convention as
    -- Questie's HereBeDragons minimap pin math).
    --------------------------------------------------------

    local xDist =
        playerX - target.x

    local yDist =
        playerY - target.y


    --------------------------------------------------------
    -- Straight-line distance (world coords are in yards).
    --------------------------------------------------------

    local distance =
        math.sqrt(
            xDist * xDist
            + yDist * yDist
        )

    target.distance = distance


    --------------------------------------------------------
    -- Reached the objective: hide instead of jittering.
    --
    -- For a point objective the radius is 0, so the arrow
    -- hides when within ARRIVAL_DISTANCE. For an area
    -- objective the radius is the extent of the spawn
    -- cluster, so the arrow hides as soon as the player
    -- steps inside the area (while still pointing at its
    -- center when outside).
    --------------------------------------------------------

    local arrival = ARRIVAL_DISTANCE

    if target.radius and target.radius > arrival then
        arrival = target.radius
    end

    if arrival > MAX_AREA_RADIUS then
        arrival = MAX_AREA_RADIUS
    end

    if distance < arrival then
        arrow:Hide()
        return
    end


    --------------------------------------------------------
    -- Tint the arrow red (far) -> green (near).
    --------------------------------------------------------

    local r
    local g
    local b

    r, g, b = GetArrowColor(distance)

    arrow.texture:SetVertexColor(r, g, b, 1)


    --------------------------------------------------------
    -- Rotating minimap: rotate the delta by the player facing
    -- so that "up" on the minimap equals the facing direction.
    -- (Same matrix as Questie's HBD.lua drawMinimapPin.)
    --------------------------------------------------------

    local rotateMinimap =
        GetCVar("rotateMinimap") == "1"

    if rotateMinimap then

        local facing =
            GetPlayerFacing()

        local mapCos =
            math.cos(facing)

        local mapSin =
            math.sin(facing)

        local dx =
            xDist

        local dy =
            yDist

        xDist =
            dx * mapCos - dy * mapSin

        yDist =
            dx * mapSin + dy * mapCos
    end


    --------------------------------------------------------
    -- Screen-space direction toward the target is
    -- (xDist, -yDist): +x is right on screen, +y is up and
    -- world +y is north.
    --------------------------------------------------------

    local dirX =
        xDist / distance

    local dirY =
        -yDist / distance


    --------------------------------------------------------
    -- Place the arrow at a fixed inset distance from the
    -- minimap center (like DragonUI's native corpse arrow),
    -- pointing toward the target.
    --------------------------------------------------------

    local radius =
        math.min(
            Minimap:GetWidth(),
            Minimap:GetHeight()
        ) / 2 * DB.radiusScale

    arrow:ClearAllPoints()

    arrow:SetPoint(
        "CENTER",
        Minimap,
        "CENTER",
        dirX * radius,
        dirY * radius
    )


    --------------------------------------------------------
    -- Rotate the (up-pointing) textures toward the target.
    -- angle = bearing measured clockwise from "up".
    -- SetRotation: positive = counter-clockwise, so negate.
    -- Both body and gloss rotate together.
    --------------------------------------------------------

    local angle =
        math.atan2(dirX, dirY)

    arrow.texture:SetRotation(
        -angle
    )

    arrow.gloss:SetRotation(
        -angle
    )

    arrow:Show()
end


------------------------------------------------------------
-- UPDATE ARROW TOOLTIP
--
-- The arrow is mouse-transparent, so native minimap tooltips
-- (town names, POI markers) keep working. We detect hover via
-- IsMouseOver() and either:
--   * append the quest name to a native tooltip that is
--     already showing (merged into one tooltip), or
--   * show a standalone tooltip owned by the arrow.
------------------------------------------------------------

------------------------------------------------------------
-- Copies the exact font (face, size, flags) from a reference
-- FontString onto a target FontString, so our tooltip text
-- matches the native tooltip text pixel-for-pixel.
------------------------------------------------------------

local function MatchTooltipFont(target, reference)

    if not target or not reference then
        return
    end

    ----------------------------------------------------
    -- Prefer copying the concrete font (face, size, flags).
    ----------------------------------------------------

    local font, size, flags = reference:GetFont()

    if font then
        target:SetFont(font, size, flags)
        return
    end

    ----------------------------------------------------
    -- Fallback: copy the font object (handles tooltip
    -- FontStrings that inherit via XML).
    ----------------------------------------------------

    if reference.GetFontObject then

        local fontObject = reference:GetFontObject()

        if fontObject then
            target:SetFontObject(fontObject)
        end
    end
end


------------------------------------------------------------
-- Returns true if the quest-name line is already present in
-- the tooltip. We use this instead of remembering the owner,
-- because native tooltips get re-filled (their lines are
-- wiped) and re-checking content is far more robust.
------------------------------------------------------------

local function TooltipHasText(text)

    if not GameTooltip then
        return false
    end

    local n = GameTooltip:NumLines()

    for i = 1, n do

        local line = _G["GameTooltipTextLeft" .. i]

        if line and line:GetText() == text then
            return true
        end
    end

    return false
end


------------------------------------------------------------
-- True when the cursor is over the VISIBLE arrow, not just
-- over its (larger) frame rectangle. The arrow frame is
-- DB.size x DB.size, but the arrow art leaves transparent
-- margins, so the frame's IsMouseOver() reports "hover" even
-- in those margins. Using a radius matched to the art avoids
-- false merges when a gap separates the arrow from a nearby
-- tooltip-producing object.
------------------------------------------------------------

local function IsCursorOverArrow()

    if not arrow or not arrow:IsShown() then
        return false
    end

    local scale = UIParent:GetEffectiveScale()

    if not scale or scale <= 0 then
        scale = 1
    end

    local cursorX
    local cursorY

    cursorX, cursorY = GetCursorPosition()

    local centerX
    local centerY

    centerX, centerY = arrow:GetCenter()

    local dx = (cursorX / scale) - centerX
    local dy = (cursorY / scale) - centerY

    local radius = DB.size * 0.30

    return (dx * dx + dy * dy) <= (radius * radius)
end


local function UpdateArrowTooltip()

    local tt = arrow and arrow.questTooltip

    ----------------------------------------------------
    -- Hide our standalone tooltip when the arrow is gone
    -- or the cursor moved off it.
    ----------------------------------------------------

    if not arrow
        or not arrow:IsShown()
        or not IsCursorOverArrow()
    then

        if tt then
            tt:Hide()
        end

        return
    end


    local name = target and target.name or "Quest objective"

    local owner = GameTooltip:GetOwner()

    if GameTooltip:IsShown()
        and owner
        and owner ~= arrow
    then

        ----------------------------------------------------
        -- A native tooltip is already showing: merge ours
        -- into it. Re-check content (not owner) because the
        -- native tooltip can wipe our line between ticks.
        ----------------------------------------------------

        if tt then
            tt:Hide()
        end

        if not TooltipHasText(name) then

            GameTooltip:AddLine(name, 1, 1, 1)

            ----------------------------------------------------
            -- Match the font (face, size, flags) of the native
            -- line directly above ours, so the merged tooltip
            -- looks like one native tooltip.
            ----------------------------------------------------

            local n = GameTooltip:NumLines()
            local ourLine = _G["GameTooltipTextLeft" .. n]
            local ref

            if n > 1 then
                ref = _G["GameTooltipTextLeft" .. (n - 1)]
            else
                ref = GameTooltipHeaderText
            end

            MatchTooltipFont(ourLine, ref)

            GameTooltip:Show()
        end

    else

        ----------------------------------------------------
        -- Nothing native under the cursor: show our OWN
        -- tooltip frame (immune to SetMinimapMouseover).
        ----------------------------------------------------

        if not tt then
            return
        end

        tt.text:SetText(name)

        local width = tt.text:GetStringWidth() + 24
        local height = tt.text:GetStringHeight() + 16

        tt:SetSize(width, height)

        tt:ClearAllPoints()
        tt:SetPoint("LEFT", arrow, "RIGHT", 8, 0)

        tt:Show()
    end
end


------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

QRN:RegisterEvent("ADDON_LOADED")
QRN:RegisterEvent("PLAYER_LOGIN")
QRN:RegisterEvent("PLAYER_ENTERING_WORLD")
QRN:RegisterEvent("QUEST_ACCEPTED")
QRN:RegisterEvent("QUEST_LOG_UPDATE")
QRN:RegisterEvent("QUEST_WATCH_UPDATE")
QRN:RegisterEvent("QUEST_POI_UPDATE")
QRN:RegisterEvent("ZONE_CHANGED")
QRN:RegisterEvent("ZONE_CHANGED_NEW_AREA")


------------------------------------------------------------
-- EVENT HANDLER
------------------------------------------------------------

QRN:SetScript(
    "OnEvent",
    function(_, event, arg1)

        ----------------------------------------------------
        -- Load saved arrow placement once.
        ----------------------------------------------------

        if event == "ADDON_LOADED"
            and arg1 == "QuestieRetailMinimapNav"
        then

            if QRNNavDB then
                for k, v in pairs(QRNNavDB) do
                    DB[k] = v
                end
            end

            QRNNavDB = DB

            return
        end


        CreateArrow()

        arrowTimer = 0

        ----------------------------------------------------
        -- On a real (re)load the old target is stale, so clear
        -- it. On quest/zone events keep the current arrow and
        -- just force a re-acquisition — this avoids the arrow
        -- flickering off for up to TARGET_INTERVAL during zone
        -- transitions.
        ----------------------------------------------------

        if event == "PLAYER_LOGIN"
            or event == "PLAYER_ENTERING_WORLD"
        then

            target = nil
            targetTimer = TARGET_INTERVAL

        else

            targetTimer = TARGET_INTERVAL
        end
    end
)


------------------------------------------------------------
-- UPDATE
------------------------------------------------------------

QRN:SetScript(
    "OnUpdate",
    function(_, elapsed)

        targetTimer =
            targetTimer + elapsed

        arrowTimer =
            arrowTimer + elapsed

        tooltipTimer =
            tooltipTimer + elapsed


        ----------------------------------------------------
        -- Re-acquire the nearest objective.
        ----------------------------------------------------

        if targetTimer >=
            TARGET_INTERVAL
        then

            targetTimer = 0

            UpdateTarget()
        end


        ----------------------------------------------------
        -- Smooth arrow updates.
        ----------------------------------------------------

        if arrowTimer >=
            ARROW_INTERVAL
        then

            arrowTimer = 0

            UpdateArrow()
        end


        ----------------------------------------------------
        -- Hover tooltip (merged with native minimap tooltips).
        ----------------------------------------------------

        if tooltipTimer >=
            TOOLTIP_INTERVAL
        then

            tooltipTimer = 0

            UpdateArrowTooltip()
        end
    end
)