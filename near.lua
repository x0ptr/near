-- Near - Shows nearby enemies and players
-- Author: x0ptr

local ADDON_NAME = "near"
local VERSION = "1.1.1"

-- Saved variables
NearDB = NearDB or {
    enemyFramePos = {},
    friendlyFramePos = {},
    fontSize = 12,
    frameWidth = 300
}

-- Frame for event handling
local frame = CreateFrame("Frame")

-- Database connection
local db = nil

-- Display frames
local enemyDisplayFrame = nil
local friendlyDisplayFrame = nil
local enemyFrames = {}
local friendlyFrames = {}
local enemyPlayerFrame = nil
local friendlyPlayerFrame = nil
local updateTimer = 0
local UPDATE_INTERVAL = 0.1 -- Update 10 times per second

-- Initialize addon
local function Initialize()
    print("|cFF00FF00Near|r " .. VERSION .. " loaded. Type |cFFFFFF00/ne|r (enemies) or |cFFFFFF00/nf|r (players).")
    
    -- Initialize AzerothDB connection
    if AzerothDB then
        db = AzerothDB:CreateConnection("near")
        
        if db then
            -- Create nameplates table with GUID as primary key
            db:CreateTable("nameplates", {
                guid = {type = "string", primary = true},
                name = {type = "string", required = true},
                unitType = {type = "string"},
                level = {type = "number", default = 0},
                isPlayer = {type = "boolean", default = false},
                firstSeen = {type = "number"},
                lastSeen = {type = "number"},
                seenCount = {type = "number", default = 0}
            })
            
            -- Create indexes for fast lookups
            db:CreateIndex("nameplates", "name")
            db:CreateIndex("nameplates", "unitType")
            
            print("|cFF00FF00Near|r AzerothDB integration active.")
        else
            print("|cFFFF0000Near|r Error: Could not create database connection.")
        end
    else
        print("|cFFFF0000Near|r Warning: AzerothDB not found. Database features disabled.")
    end
end

-- Get nearby nameplates and entities
local function GetNearbyEntities()
    local entities = {}
    local nameplatesToScan = {}
    
    -- Collect all visible nameplates
    for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
        if nameplate and nameplate:IsVisible() then
            table.insert(nameplatesToScan, nameplate)
        end
    end
    
    -- Extract information from nameplates
    for _, nameplate in ipairs(nameplatesToScan) do
        local unit = nameplate.namePlateUnitToken
        if unit and UnitExists(unit) then
            local name = UnitName(unit)
            local unitType = "Unknown"
            
            -- Determine unit type
            if UnitIsPlayer(unit) then
                unitType = "Player"
            elseif UnitIsEnemy("player", unit) then
                unitType = "Enemy"
            elseif UnitIsFriend("player", unit) then
                unitType = "Friendly NPC"
            else
                unitType = "NPC"
            end
            
            -- Add reaction color
            local reaction = UnitReaction(unit, "player")
            local color = "|cFFFFFFFF" -- Default white
            if reaction then
                if reaction <= 2 then
                    color = "|cFFFF0000" -- Hostile (red)
                elseif reaction == 3 then
                    color = "|cFFFFFF00" -- Neutral (yellow)
                elseif reaction >= 4 then
                    color = "|cFF00FF00" -- Friendly (green)
                end
            end
            
            -- Get health info
            local health = UnitHealth(unit)
            local healthMax = UnitHealthMax(unit)
            local healthPercent = 0
            if healthMax > 0 then
                healthPercent = math.floor((health / healthMax) * 100)
            end
            
            -- Extract nameplate number for basic ordering (lower numbers are typically closer)
            local distance = 999
            local nameplateNum = unit:match("nameplate(%d+)")
            if nameplateNum then
                distance = tonumber(nameplateNum)
            end
            
            -- Check if in attack range
            local inRange = false
            if UnitCanAttack("player", unit) then
                inRange = CheckInteractDistance(unit, 3) -- 3 = 10 yards (melee range check)
                if not inRange then
                    inRange = IsItemInRange(37727, unit) or false -- 5-20 yard check
                end
            end
            
            -- Check if targeting player
            local isTargetingMe = UnitIsUnit(unit .. "target", "player")
            
            -- Check if player is targeting this unit
            local isMyTarget = UnitIsUnit("target", unit)
            
            -- Store entity data
            if name then
                -- Get GUID for database storage
                local guid = UnitGUID(unit)
                
                local entityData = {
                    name = name,
                    type = unitType,
                    color = color,
                    health = health,
                    healthMax = healthMax,
                    healthPercent = healthPercent,
                    unit = unit,
                    isDead = UnitIsDead(unit),
                    level = UnitLevel(unit),
                    distance = distance,
                    isEnemy = UnitIsEnemy("player", unit),
                    isFriendly = UnitIsFriend("player", unit),
                    inRange = inRange,
                    isTargetingMe = isTargetingMe,
                    isMyTarget = isMyTarget,
                    isPlayer = UnitIsPlayer(unit),
                    guid = guid
                }
                
                table.insert(entities, entityData)
                
                -- Store in AzerothDB if GUID exists
                if guid and db then
                    local existing = db:SelectByPK("nameplates", guid)
                    if existing then
                        -- Update existing entry
                        db:UpdateByPK("nameplates", guid, function(row)
                            row.name = name
                            row.unitType = unitType
                            row.level = UnitLevel(unit)
                            row.isPlayer = UnitIsPlayer(unit)
                            row.lastSeen = time()
                            row.seenCount = (row.seenCount or 0) + 1
                        end)
                    else
                        -- Insert new entry
                        db:Insert("nameplates", {
                            guid = guid,
                            name = name,
                            unitType = unitType,
                            level = UnitLevel(unit),
                            isPlayer = UnitIsPlayer(unit),
                            firstSeen = time(),
                            lastSeen = time(),
                            seenCount = 1
                        })
                    end
                end
            end
        end
    end
    
    return entities
end

-- Get nearby players (scanning party, raid, and nearby units)
local function GetNearbyPlayers()
    local players = {}
    local scannedUnits = {}
    
    -- Scan party members
    if IsInGroup() then
        for i = 1, GetNumGroupMembers() do
            local unit = IsInRaid() and "raid" .. i or "party" .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local guid = UnitGUID(unit)
                if guid and not scannedUnits[guid] then
                    scannedUnits[guid] = true
                    
                    local name = UnitName(unit)
                    local health = UnitHealth(unit)
                    local healthMax = UnitHealthMax(unit)
                    local healthPercent = (healthMax > 0) and math.floor((health / healthMax) * 100) or 100
                    
                    -- Check range
                    local inRange = UnitInRange(unit) or false
                    
                    -- Check if targeting player
                    local isTargetingMe = UnitIsUnit(unit .. "target", "player")
                    local isMyTarget = UnitIsUnit("target", unit)
                    
                    table.insert(players, {
                        name = name,
                        unit = unit,
                        health = health,
                        healthMax = healthMax,
                        healthPercent = healthPercent,
                        level = UnitLevel(unit),
                        isDead = UnitIsDead(unit),
                        inRange = inRange,
                        isTargetingMe = isTargetingMe,
                        isMyTarget = isMyTarget,
                        distance = inRange and 1 or 999,
                        isPlayer = true
                    })
                end
            end
        end
    end
    
    return players
end

-- Update player status frame
local function UpdatePlayerStatus(frame)
    if not frame or not frame:IsShown() then return end
    
    -- Get player stats
    local health = UnitHealth("player")
    local healthMax = UnitHealthMax("player")
    local healthPercent = (healthMax > 0) and (health / healthMax * 100) or 100
    
    local power = UnitPower("player")
    local powerMax = UnitPowerMax("player")
    local powerPercent = (powerMax > 0) and (power / powerMax * 100) or 0
    local powerType = UnitPowerType("player")
    
    -- Check debuffs for stun/slow
    local isStunned = false
    local isSlowed = false
    
    local debuffs = C_UnitAuras.GetAuraSlots("player", "HARMFUL")
    if debuffs then
        for _, slot in ipairs(debuffs) do
            local auraData = C_UnitAuras.GetAuraDataBySlot("player", slot)
            if auraData then
                local name = auraData.name
                local dispelName = auraData.dispelName
                
                if name then
                    local lowerName = name:lower()
                    -- Check for stun/incapacitate
                    if lowerName:find("stun") or lowerName:find("incapacitate") or 
                       lowerName:find("sap") or lowerName:find("polymorph") or
                       lowerName:find("fear") or lowerName:find("horror") or
                       lowerName:find("charm") or lowerName:find("cyclone") then
                        isStunned = true
                    end
                    -- Check for slow/snare
                    if lowerName:find("slow") or lowerName:find("snare") or 
                       lowerName:find("chill") or lowerName:find("frost") or
                       lowerName:find("root") or lowerName:find("entangle") then
                        isSlowed = true
                    end
                end
            end
        end
    end
    
    -- Player name
    local playerName = UnitName("player")
    frame.nameText:SetText(playerName)
    
    -- Status indicators and percentages
    local statusStr = ""
    if isStunned then
        statusStr = statusStr .. "|cFFFF0000[ST]|r "
    end
    if isSlowed then
        statusStr = statusStr .. "|cFF00FFFF[SL]|r "
    end
    statusStr = statusStr .. string.format("HP:%3d%%", math.floor(healthPercent))
    
    -- Add mana/resource if relevant
    if powerMax > 0 then
        local powerName = "MP"
        if powerType == 1 then powerName = "RG" -- Rage
        elseif powerType == 2 then powerName = "FC" -- Focus
        elseif powerType == 3 then powerName = "EN" -- Energy
        elseif powerType == 6 then powerName = "RP" -- Runic Power
        end
        statusStr = statusStr .. string.format(" %s:%3d%%", powerName, math.floor(powerPercent))
    end
    
    frame.statusText:SetText(statusStr)
    
    -- Set health background bar
    local frameWidth = frame:GetWidth()
    frame.healthBg:SetWidth((frameWidth - 10) * (healthPercent / 100))
    
    -- Color health bar
    if healthPercent > 50 then
        frame.healthBg:SetColorTexture(0, 1, 0, 0.3)
    elseif healthPercent > 25 then
        frame.healthBg:SetColorTexture(1, 1, 0, 0.3)
    else
        frame.healthBg:SetColorTexture(1, 0, 0, 0.3)
    end
    
    -- Set mana bar if applicable (layered on top)
    if powerMax > 0 then
        frame.manaBg:SetWidth((frameWidth - 10) * (powerPercent / 100))
        frame.manaBg:Show()
    else
        frame.manaBg:Hide()
    end
end

-- Display nearby entities in chat
local function ShowNearbyEntities()
    local entities = GetNearbyEntities()
    
    if #entities == 0 then
        print("|cFF00FF00[NameList]|r No nearby entities with visible nameplates found.")
        return
    end
    
    print("|cFF00FF00[NameList]|r Found " .. #entities .. " nearby entities:")
    print("-------------------------------------------")
    
    for i, entity in ipairs(entities) do
        local statusIcon = entity.isDead and "|cFFFF0000[DEAD]|r " or ""
        local levelStr = entity.level > 0 and "[" .. entity.level .. "] " or ""
        local healthStr = entity.healthPercent > 0 and " (" .. entity.healthPercent .. "% HP)" or ""
        
        print(string.format("%d. %s%s%s|r - %s%s",
            i,
            statusIcon,
            levelStr,
            entity.color .. entity.name,
            entity.type,
            healthStr
        ))
    end
    
    print("-------------------------------------------")
end

-- Create a unit frame for display (list style)
local function CreateUnitFrame(parent, index)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(250, 32)
    f:SetPoint("TOP", parent, "TOP", 0, -5 - (index - 1) * 32)
    
    -- Health background bar
    f.healthBg = f:CreateTexture(nil, "BACKGROUND")
    f.healthBg:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.healthBg:SetHeight(14)
    f.healthBg:SetColorTexture(0, 1, 0, 0.3)
    
    -- Dark background for empty health
    f.emptyBg = f:CreateTexture(nil, "BACKGROUND")
    f.emptyBg:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.emptyBg:SetHeight(14)
    f.emptyBg:SetColorTexture(0.2, 0.2, 0.2, 0.5)
    
    -- Name text (fixed width, truncated with ...)
    f.nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.nameText:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.nameText:SetJustifyH("LEFT")
    f.nameText:SetWordWrap(false)
    f.nameText:SetNonSpaceWrap(false)
    
    -- Health/status text (right aligned, fixed position)
    f.healthText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.healthText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -4)
    f.healthText:SetJustifyH("RIGHT")
    f.healthText:SetWordWrap(false)
    f.healthText:SetNonSpaceWrap(false)
    f.healthText:SetWidth(50)
    
    -- Cast/Action text (second row)
    f.castText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.castText:SetPoint("TOPLEFT", f.nameText, "BOTTOMLEFT", 0, -2)
    f.castText:SetJustifyH("LEFT")
    f.castText:SetWordWrap(false)
    f.castText:SetNonSpaceWrap(false)
    
    f:Hide()
    return f
end

-- Create player status frame
local function CreatePlayerStatusFrame(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(250, 24)
    f:SetPoint("BOTTOM", parent, "TOP", 0, -5)
    
    -- Health background bar
    f.healthBg = f:CreateTexture(nil, "BACKGROUND")
    f.healthBg:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.healthBg:SetHeight(16)
    f.healthBg:SetColorTexture(0, 1, 0, 0.3)
    
    -- Mana background bar (layered on top of health)
    f.manaBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.manaBg:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.manaBg:SetHeight(16)
    f.manaBg:SetColorTexture(0, 0, 1, 0.3)
    
    -- Dark background for empty
    f.emptyBg = f:CreateTexture(nil, "BACKGROUND")
    f.emptyBg:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.emptyBg:SetHeight(16)
    f.emptyBg:SetColorTexture(0.2, 0.2, 0.2, 0.5)
    
    -- Player name and stats
    f.nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.nameText:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -4)
    f.nameText:SetJustifyH("LEFT")
    f.nameText:SetWordWrap(false)
    f.nameText:SetNonSpaceWrap(false)
    
    -- Status indicators and percentages
    f.statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.statusText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -4)
    f.statusText:SetJustifyH("RIGHT")
    f.statusText:SetWordWrap(false)
    f.statusText:SetNonSpaceWrap(false)
    f.statusText:SetWidth(150)
    
    f:Hide()
    return f
end

-- Update font sizes for all frames
local function UpdateFontSizes()
    local fontPath = GameFontNormal:GetFont()
    local fontSize = NearDB.fontSize or 12
    
    for i = 1, 10 do
        if enemyFrames[i] then
            enemyFrames[i].nameText:SetFont(fontPath, fontSize, "OUTLINE")
            enemyFrames[i].healthText:SetFont(fontPath, fontSize, "OUTLINE")
            enemyFrames[i].castText:SetFont(fontPath, fontSize, "OUTLINE")
        end
        if friendlyFrames[i] then
            friendlyFrames[i].nameText:SetFont(fontPath, fontSize, "OUTLINE")
            friendlyFrames[i].healthText:SetFont(fontPath, fontSize, "OUTLINE")
            friendlyFrames[i].castText:SetFont(fontPath, fontSize, "OUTLINE")
        end
    end
    
    if enemyPlayerFrame then
        enemyPlayerFrame.nameText:SetFont(fontPath, fontSize, "OUTLINE")
        enemyPlayerFrame.statusText:SetFont(fontPath, fontSize, "OUTLINE")
    end
    
    if friendlyPlayerFrame then
        friendlyPlayerFrame.nameText:SetFont(fontPath, fontSize, "OUTLINE")
        friendlyPlayerFrame.statusText:SetFont(fontPath, fontSize, "OUTLINE")
    end
end

-- Update frame widths
local function UpdateFrameWidths()
    local width = NearDB.frameWidth or 300
    
    if enemyDisplayFrame then
        enemyDisplayFrame:SetWidth(width)
        for i = 1, 10 do
            if enemyFrames[i] then
                enemyFrames[i]:SetWidth(width - 10)
                enemyFrames[i].nameText:SetWidth(width - 65)  -- Use maximum space for name
                enemyFrames[i].healthText:SetWidth(50)
                enemyFrames[i].castText:SetWidth(width - 15)
                enemyFrames[i].emptyBg:SetWidth(width - 75)
            end
        end
        if enemyPlayerFrame then
            enemyPlayerFrame:SetWidth(width - 10)
            enemyPlayerFrame.nameText:SetWidth(width - 165)
            enemyPlayerFrame.emptyBg:SetWidth(width - 75)
        end
    end
    
    if friendlyDisplayFrame then
        friendlyDisplayFrame:SetWidth(width)
        for i = 1, 10 do
            if friendlyFrames[i] then
                friendlyFrames[i]:SetWidth(width - 10)
                friendlyFrames[i].nameText:SetWidth(width - 65)  -- Use maximum space for name
                friendlyFrames[i].healthText:SetWidth(50)
                friendlyFrames[i].castText:SetWidth(width - 15)
                friendlyFrames[i].emptyBg:SetWidth(width - 75)
            end
        end
        if friendlyPlayerFrame then
            friendlyPlayerFrame:SetWidth(width - 10)
            friendlyPlayerFrame.nameText:SetWidth(width - 165)
            friendlyPlayerFrame.emptyBg:SetWidth(width - 75)
        end
    end
end

-- Create or get the enemy display frame
local function GetEnemyDisplayFrame()
    if not enemyDisplayFrame then
        local width = NearDB.frameWidth or 300
        enemyDisplayFrame = CreateFrame("Frame", "WowNameListEnemyFrame", UIParent, "BackdropTemplate")
        enemyDisplayFrame:SetSize(width, 350)
        
        -- Restore saved position or use default
        if NearDB.enemyFramePos and NearDB.enemyFramePos.point then
            enemyDisplayFrame:SetPoint(
                NearDB.enemyFramePos.point,
                UIParent,
                NearDB.enemyFramePos.relativePoint,
                NearDB.enemyFramePos.xOfs,
                NearDB.enemyFramePos.yOfs
            )
        else
            enemyDisplayFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -200)
        end
        
        enemyDisplayFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        enemyDisplayFrame:SetBackdropColor(0, 0, 0, 0.85)
        enemyDisplayFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        enemyDisplayFrame:EnableMouse(true)
        enemyDisplayFrame:SetMovable(true)
        enemyDisplayFrame:RegisterForDrag("LeftButton")
        enemyDisplayFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        enemyDisplayFrame:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            -- Save position
            local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
            NearDB.enemyFramePos = {
                point = point,
                relativePoint = relativePoint,
                xOfs = xOfs,
                yOfs = yOfs
            }
        end)
        
        -- Create unit frames
        for i = 1, 10 do
            enemyFrames[i] = CreateUnitFrame(enemyDisplayFrame, i)
        end
        
        -- Create player status frame
        enemyPlayerFrame = CreatePlayerStatusFrame(enemyDisplayFrame)
        
        UpdateFontSizes()
        UpdateFrameWidths()
        
        enemyDisplayFrame:Hide()
    end
    return enemyDisplayFrame
end

-- Create or get the friendly display frame
local function GetFriendlyDisplayFrame()
    if not friendlyDisplayFrame then
        local width = NearDB.frameWidth or 300
        friendlyDisplayFrame = CreateFrame("Frame", "WowNameListFriendlyFrame", UIParent, "BackdropTemplate")
        friendlyDisplayFrame:SetSize(width, 350)
        
        -- Restore saved position or use default
        if NearDB.friendlyFramePos and NearDB.friendlyFramePos.point then
            friendlyDisplayFrame:SetPoint(
                NearDB.friendlyFramePos.point,
                UIParent,
                NearDB.friendlyFramePos.relativePoint,
                NearDB.friendlyFramePos.xOfs,
                NearDB.friendlyFramePos.yOfs
            )
        else
            friendlyDisplayFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -200)
        end
        
        friendlyDisplayFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        friendlyDisplayFrame:SetBackdropColor(0, 0, 0, 0.85)
        friendlyDisplayFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        friendlyDisplayFrame:EnableMouse(true)
        friendlyDisplayFrame:SetMovable(true)
        friendlyDisplayFrame:RegisterForDrag("LeftButton")
        friendlyDisplayFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        friendlyDisplayFrame:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            -- Save position
            local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
            NearDB.friendlyFramePos = {
                point = point,
                relativePoint = relativePoint,
                xOfs = xOfs,
                yOfs = yOfs
            }
        end)
        
        -- Create unit frames
        for i = 1, 10 do
            friendlyFrames[i] = CreateUnitFrame(friendlyDisplayFrame, i)
        end
        
        -- Create player status frame
        friendlyPlayerFrame = CreatePlayerStatusFrame(friendlyDisplayFrame)
        
        UpdateFontSizes()
        UpdateFrameWidths()
        
        friendlyDisplayFrame:Hide()
    end
    return friendlyDisplayFrame
end

-- Update the display frames
local function UpdateDisplayFrames()
    local entities = GetNearbyEntities()
    local players = GetNearbyPlayers()
    
    -- Check if nameplates are enabled
    local enemyNameplatesEnabled = GetCVar("nameplateShowEnemies") == "1"
    local friendlyNameplatesEnabled = GetCVar("nameplateShowFriends") == "1"
    
    -- Update player status frames
    if enemyDisplayFrame and enemyDisplayFrame:IsShown() then
        UpdatePlayerStatus(enemyPlayerFrame)
        enemyPlayerFrame:Show()
    end
    
    if friendlyDisplayFrame and friendlyDisplayFrame:IsShown() then
        UpdatePlayerStatus(friendlyPlayerFrame)
        friendlyPlayerFrame:Show()
    end
    
    -- Separate and sort enemies and friendlies by distance
    local enemies = {}
    local friendlies = {}
    
    for _, entity in ipairs(entities) do
        -- Use reaction to determine enemy/friendly (reaction <= 2 is hostile/enemy)
        local reaction = UnitReaction(entity.unit, "player")
        
        if reaction and reaction <= 2 and not entity.isDead then
            -- Enemy (hostile/unfriendly)
            table.insert(enemies, entity)
        elseif entity.isPlayer and not entity.isDead and not UnitIsUnit(entity.unit, "player") then
            -- Players from nameplates (exclude self)
            table.insert(friendlies, entity)
        end
    end
    
    -- Add party/raid players to friendlies
    for _, player in ipairs(players) do
        if not player.isDead then
            table.insert(friendlies, player)
        end
    end
    
    -- Sort by distance (closest first)
    table.sort(enemies, function(a, b)
        -- In-range enemies first, then sort by distance
        if a.inRange ~= b.inRange then
            return a.inRange
        end
        return a.distance < b.distance
    end)
    table.sort(friendlies, function(a, b)
        if a.inRange ~= b.inRange then
            return a.inRange
        end
        return a.distance < b.distance
    end)
    
    -- Update enemy frames
    if enemyDisplayFrame and enemyDisplayFrame:IsShown() then
        -- Check if enemy nameplates are disabled
        if not enemyNameplatesEnabled then
            -- Hide all enemy frames and show warning
            for i = 1, 10 do
                enemyFrames[i]:Hide()
            end
            
            -- Show warning in first frame
            local frame = enemyFrames[1]
            frame.nameText:SetText("|cFFFF0000⚠ NAMEPLATES DISABLED ⚠|r")
            frame.healthText:SetText("")
            frame.castText:SetText("|cFFFFFF00Enable: Interface → Names → Enemy Units|r")
            frame.healthBg:SetWidth(0)
            frame:Show()
        else
            -- Normal enemy frame updates
            for i = 1, 10 do
                local frame = enemyFrames[i]
                if enemies[i] then
                    local entity = enemies[i]
                
                -- Build health indicator (4 dashes, each representing 25%)
                local healthPercent = 0
                if entity.healthMax > 0 then
                    healthPercent = (entity.health / entity.healthMax) * 100
                end
                
                -- Build name line with range indicator
                local levelStr = entity.level > 0 and "[" .. entity.level .. "] " or ""
                local rangeIndicator = entity.inRange and "|cFFFF0000[R]|r " or ""
                local targetIndicator = entity.isTargetingMe and "|cFFFF0000[T]|r " or ""
                local myTargetIndicator = entity.isMyTarget and "|cFFFFFFFF>|r " or ""
                local nameColor = entity.inRange and "|cFFFFFF00" or "|cFFFFFFFF"
                
                -- Name on left (truncated)
                frame.nameText:SetText(string.format("%s%s%s%s%s|r", 
                    myTargetIndicator, rangeIndicator, targetIndicator, levelStr, nameColor .. entity.name))
                
                -- Health percentage on right
                frame.healthText:SetText(string.format("%3d%%", math.floor(healthPercent)))
                
                -- Set health background bar width and color (full frame width)
                local frameWidth = frame:GetWidth()
                frame.healthBg:SetWidth((frameWidth - 10) * (healthPercent / 100))
                
                -- Color health bar based on percentage
                if healthPercent > 50 then
                    frame.healthBg:SetColorTexture(0, 1, 0, 0.3)
                elseif healthPercent > 25 then
                    frame.healthBg:SetColorTexture(1, 1, 0, 0.3)
                else
                    frame.healthBg:SetColorTexture(1, 0, 0, 0.3)
                end
                
                -- Check for casting
                
                -- Check for casting
                local casting = UnitCastingInfo(entity.unit)
                local channeling = UnitChannelInfo(entity.unit)
                
                if casting then
                    local spellName, _, _, _, _, _, _, notInterruptible = UnitCastingInfo(entity.unit)
                    if notInterruptible then
                        frame.castText:SetText("|cFF666666→ " .. spellName .. "|r")
                    else
                        frame.castText:SetText("|cFFFF8800>>> KICK: " .. spellName .. " <<<|r")
                    end
                elseif channeling then
                    local spellName, _, _, _, _, _, notInterruptible = UnitChannelInfo(entity.unit)
                    if notInterruptible then
                        frame.castText:SetText("|cFF666666→ " .. spellName .. "|r")
                    else
                        frame.castText:SetText("|cFFFF8800>>> KICK: " .. spellName .. " <<<|r")
                    end
                else
                    frame.castText:SetText("")
                end
                
                frame:Show()
            else
                frame:Hide()
            end
        end
        end
    end
    
    -- Update friendly frames
    if friendlyDisplayFrame and friendlyDisplayFrame:IsShown() then
        -- Check if friendly nameplates are disabled
        if not friendlyNameplatesEnabled and #players == 0 then
            -- Hide all friendly frames and show warning
            for i = 1, 10 do
                friendlyFrames[i]:Hide()
            end
            
            -- Show warning in first frame
            local frame = friendlyFrames[1]
            frame.nameText:SetText("|cFFFF0000⚠ NAMEPLATES DISABLED ⚠|r")
            frame.healthText:SetText("")
            frame.castText:SetText("|cFFFFFF00Enable: Interface → Names → Friendly Units|r")
            frame.healthBg:SetWidth(0)
            frame:Show()
        else
            -- Normal friendly frame updates
            for i = 1, 10 do
                local frame = friendlyFrames[i]
                if friendlies[i] then
                    local entity = friendlies[i]
                
                -- Build health indicator (4 dashes, each representing 25%)
                local healthPercent = 0
                if entity.healthMax > 0 then
                    healthPercent = (entity.health / entity.healthMax) * 100
                end
                
                -- Build name line with range indicator
                local levelStr = entity.level > 0 and "[" .. entity.level .. "] " or ""
                local rangeIndicator = entity.inRange and "|cFF00FF00[R]|r " or ""
                local targetIndicator = entity.isTargetingMe and "|cFFFFFF00[T]|r " or ""
                local myTargetIndicator = entity.isMyTarget and "|cFFFFFFFF>|r " or ""
                local nameColor = entity.inRange and "|cFF00FFFF" or "|cFFFFFFFF"
                
                -- Name on left (truncated)
                frame.nameText:SetText(string.format("%s%s%s%s%s|r", 
                    myTargetIndicator, rangeIndicator, targetIndicator, levelStr, nameColor .. entity.name))
                
                -- Health percentage on right
                frame.healthText:SetText(string.format("%3d%%", math.floor(healthPercent)))
                
                -- Set health background bar width and color (full frame width)
                local frameWidth = frame:GetWidth()
                frame.healthBg:SetWidth((frameWidth - 10) * (healthPercent / 100))
                
                -- Color health bar based on percentage
                if healthPercent > 50 then
                    frame.healthBg:SetColorTexture(0, 1, 0, 0.3)
                elseif healthPercent > 25 then
                    frame.healthBg:SetColorTexture(1, 1, 0, 0.3)
                else
                    frame.healthBg:SetColorTexture(1, 0, 0, 0.3)
                end
                
                frame.unitToken = entity.unit
                
                -- Check for casting
                local casting = UnitCastingInfo(entity.unit)
                local channeling = UnitChannelInfo(entity.unit)
                
                if casting then
                    local spellName, _, _, _, _, _, _, notInterruptible = UnitCastingInfo(entity.unit)
                    if notInterruptible then
                        frame.castText:SetText("|cFF666666→ " .. spellName .. "|r")
                    else
                        frame.castText:SetText("|cFFFF8800>>> KICK: " .. spellName .. " <<<|r")
                    end
                elseif channeling then
                    local spellName, _, _, _, _, _, notInterruptible = UnitChannelInfo(entity.unit)
                    if notInterruptible then
                        frame.castText:SetText("|cFF666666→ " .. spellName .. "|r")
                    else
                        frame.castText:SetText("|cFFFF8800>>> KICK: " .. spellName .. " <<<|r")
                    end
                else
                    frame.castText:SetText("")
                end
                
                frame:Show()
            else
                frame:Hide()
            end
        end
        end
    end
end

-- Show enemy display
local function ShowEnemyDisplay()
    local displayFrame = GetEnemyDisplayFrame()
    if displayFrame:IsShown() then
        displayFrame:Hide()
    else
        displayFrame:Show()
        UpdateDisplayFrames()
    end
end

-- Show friendly display
local function ShowFriendlyDisplay()
    local displayFrame = GetFriendlyDisplayFrame()
    if displayFrame:IsShown() then
        displayFrame:Hide()
    else
        displayFrame:Show()
        UpdateDisplayFrames()
    end
end

-- Slash command handler
local function SlashCommandHandler(msg)
    msg = strtrim(msg:lower())
    
    if msg == "" or msg == "list" or msg == "show" then
        ShowNearbyEntities()
    elseif msg == "enemy-show" or msg == "enemies" or msg == "enemy" then
        ShowEnemyDisplay()
    elseif msg == "friendly-show" or msg == "friendlies" or msg == "friendly" then
        ShowFriendlyDisplay()
    elseif msg:match("^fontsize%s+(%d+)$") then
        local size = tonumber(msg:match("^fontsize%s+(%d+)$"))
        if size and size >= 8 and size <= 24 then
            NearDB.fontSize = size
            UpdateFontSizes()
            print("|cFF00FF00[NameList]|r Font size set to " .. size)
        else
            print("|cFF00FF00[NameList]|r Font size must be between 8 and 24")
        end
    elseif msg:match("^width%s+(%d+)$") then
        local width = tonumber(msg:match("^width%s+(%d+)$"))
        if width and width >= 200 and width <= 600 then
            NearDB.frameWidth = width
            UpdateFrameWidths()
            print("|cFF00FF00[NameList]|r Frame width set to " .. width)
        else
            print("|cFF00FF00[NameList]|r Width must be between 200 and 600")
        end
    elseif msg == "settings" or msg == "config" then
        print("|cFF00FF00[NameList]|r Current Settings:")
        print("  Font Size: " .. (NearDB.fontSize or 12))
        print("  Frame Width: " .. (NearDB.frameWidth or 300))
    elseif msg == "help" then
        print("|cFF00FF00[NameList]|r Commands:")
        print("  |cFFFFFF00/near|r - List nearby entities")
        print("  |cFFFFFF00/ne|r - Toggle enemy display frame")
        print("  |cFFFFFF00/nf|r - Toggle players display frame")
        print("  |cFFFFFF00/near fontsize <8-24>|r - Set font size")
        print("  |cFFFFFF00/near width <200-600>|r - Set frame width")
        print("  |cFFFFFF00/near settings|r - Show current settings")
        print("  |cFFFFFF00/near help|r - Show this help message")
    else
        ShowNearbyEntities()
    end
end

-- Enemy slash command handler
local function EnemySlashCommandHandler(msg)
    ShowEnemyDisplay()
end

-- Friendly slash command handler
local function FriendlySlashCommandHandler(msg)
    ShowFriendlyDisplay()
end

-- Debug command handler
local function DebugSlashCommandHandler(msg)
    print("=== Near Debug Info ===")
    
    -- Get entities and players
    local entities = GetNearbyEntities()
    local players = GetNearbyPlayers()
    
    print("Nameplates found: " .. #entities)
    for i, entity in ipairs(entities) do
        local reaction = UnitReaction(entity.unit, "player")
        print(string.format("[%d] %s | Type: %s | IsPlayer: %s | Reaction: %s | Dead: %s | Unit: %s",
            i, entity.name or "Unknown", entity.type or "?", 
            tostring(entity.isPlayer), tostring(reaction), 
            tostring(entity.isDead), entity.unit or "nil"))
    end
    
    print("\nParty/Raid players found: " .. #players)
    for i, player in ipairs(players) do
        print(string.format("[%d] %s | Level: %s | InRange: %s | Dead: %s | Unit: %s",
            i, player.name or "Unknown", tostring(player.level), 
            tostring(player.inRange), tostring(player.isDead), player.unit or "nil"))
    end
    
    -- Check group status
    print("\nGroup Info:")
    print("IsInGroup: " .. tostring(IsInGroup()))
    print("IsInRaid: " .. tostring(IsInRaid()))
    print("GetNumGroupMembers: " .. tostring(GetNumGroupMembers()))
    
    -- Check nameplate visibility setting
    print("\nNameplate Settings:")
    print("Enemy Nameplates: " .. tostring(GetCVar("nameplateShowEnemies")))
    print("Friendly Nameplates: " .. tostring(GetCVar("nameplateShowFriends")))
    
    print("=== End Debug ===")
end

-- Debug database slash command handler
local function DebugDBSlashCommandHandler(msg)
    if not db then
        print("|cFFFF0000[Near DB]|r AzerothDB connection not available!")
        return
    end
    
    print("|cFF00FF00=== Near Database Debug ===|r")
    
    -- Get all nameplate entries
    local nameplates = db:Select("nameplates")
    local totalCount = #nameplates
    
    print(string.format("Total nameplates stored: |cFFFFFF00%d|r", totalCount))
    print("-------------------------------------------")
    
    if totalCount == 0 then
        print("|cFFFF0000No entries found.|r")
        print("Scan some nameplates first!")
    else
        -- Sort by last seen (most recent first)
        table.sort(nameplates, function(a, b)
            return (a.lastSeen or 0) > (b.lastSeen or 0)
        end)
        
        -- Show statistics
        local playerCount = db:Count("nameplates", function(row)
            return row.isPlayer == true
        end)
        local npcCount = totalCount - playerCount
        
        print(string.format("Players: |cFF00FF00%d|r | NPCs: |cFFFFFF00%d|r", playerCount, npcCount))
        print("-------------------------------------------")
        
        -- List all entries
        for i, entry in ipairs(nameplates) do
            local typeColor = entry.isPlayer and "|cFF00FFFF" or "|cFFFFFFFF"
            local typeStr = entry.isPlayer and "Player" or "NPC"
            local levelStr = entry.level and entry.level > 0 and "[" .. entry.level .. "] " or ""
            local seenCount = entry.seenCount or 1
            local lastSeenStr = ""
            
            if entry.lastSeen then
                local elapsed = time() - entry.lastSeen
                if elapsed < 60 then
                    lastSeenStr = string.format(" (seen %ds ago)", elapsed)
                elseif elapsed < 3600 then
                    lastSeenStr = string.format(" (seen %dm ago)", math.floor(elapsed / 60))
                else
                    lastSeenStr = string.format(" (seen %dh ago)", math.floor(elapsed / 3600))
                end
            end
            
            print(string.format("%d. %s%s%s|r - %s%s | Seen: %dx%s",
                i,
                levelStr,
                typeColor,
                entry.name or "Unknown",
                typeStr,
                entry.unitType and " (" .. entry.unitType .. ")" or "",
                seenCount,
                lastSeenStr
            ))
        end
        
        print("-------------------------------------------")
        print("|cFF808080Commands:|r")
        print("  |cFFFFFF00/ndebugdb|r - Show this database info")
        print("  |cFFFFFF00/ndebugdb clear|r - Clear all database entries")
        print("  |cFFFFFF00/ndebugdb players|r - Show only players")
        print("  |cFFFFFF00/ndebugdb npcs|r - Show only NPCs")
    end
    
    -- Handle subcommands
    msg = msg:lower():trim()
    
    if msg == "clear" then
        db:Clear("nameplates")
        print("|cFF00FF00[Near DB]|r Database cleared!")
    elseif msg == "players" then
        local players = db:Select("nameplates", function(row)
            return row.isPlayer == true
        end)
        print("|cFF00FF00[Near DB]|r Found " .. #players .. " players:")
        for i, player in ipairs(players) do
            print(string.format("  %d. [%d] %s | Seen: %dx",
                i, player.level or 0, player.name, player.seenCount or 1))
        end
    elseif msg == "npcs" then
        local npcs = db:Select("nameplates", function(row)
            return row.isPlayer ~= true
        end)
        print("|cFF00FF00[Near DB]|r Found " .. #npcs .. " NPCs:")
        for i, npc in ipairs(npcs) do
            print(string.format("  %d. [%d] %s (%s) | Seen: %dx",
                i, npc.level or 0, npc.name, npc.unitType or "Unknown", npc.seenCount or 1))
        end
    end
    
    print("|cFF00FF00=== End Database Debug ===|r")
end

-- Register slash commands
SLASH_WOWNAMELIST1 = "/near"
SlashCmdList["WOWNAMELIST"] = SlashCommandHandler

SLASH_WOWNAMELISTENEMY1 = "/ne"
SlashCmdList["WOWNAMELISTENEMY"] = EnemySlashCommandHandler

SLASH_WOWNAMELISTFRIENDLY1 = "/nf"
SlashCmdList["WOWNAMELISTFRIENDLY"] = FriendlySlashCommandHandler

SLASH_WOWNAMELISTDEBUG1 = "/ndebug"
SlashCmdList["WOWNAMELISTDEBUG"] = DebugSlashCommandHandler

SLASH_WOWNAMELISTDEBUGDB1 = "/ndebugdb"
SlashCmdList["WOWNAMELISTDEBUGDB"] = DebugDBSlashCommandHandler

-- OnUpdate handler for continuous updates
local function OnUpdate(self, elapsed)
    updateTimer = updateTimer + elapsed
    if updateTimer >= UPDATE_INTERVAL then
        updateTimer = 0
        UpdateDisplayFrames()
    end
end

frame:SetScript("OnUpdate", OnUpdate)

-- Event handler
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            Initialize()
            frame:UnregisterEvent("ADDON_LOADED")
        end
    end
end)

-- Register events
frame:RegisterEvent("ADDON_LOADED")
