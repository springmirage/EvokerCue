local addonName, EC = ...

local TrackerHUD = {}
EC.TrackerHUD = TrackerHUD

local FALLBACK_ICON = 134400
local DREAM_BREATH_ID = 355936

TrackerHUD.initialized = false
TrackerHUD.frame = nil
TrackerHUD.previewActive = false
TrackerHUD.previewTimer = nil

local function GetSpellTextureSafe(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and texture then
            return texture
        end
    end

    if _G.GetSpellTexture then
        local ok, texture = pcall(_G.GetSpellTexture, spellID)
        if ok and texture then
            return texture
        end
    end

    return nil
end

function TrackerHUD:SavePosition()
    if not self.frame or not EC.state.dbReady then
        return
    end

    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    local hud = EC.db.tracker.hud
    hud.point = point or "CENTER"
    hud.relativePoint = relativePoint or "CENTER"
    hud.x = math.floor((x or 0) + 0.5)
    hud.y = math.floor((y or 0) + 0.5)
end

function TrackerHUD:RestorePosition()
    if not self.frame or not EC.state.dbReady then
        return
    end

    local hud = EC.db.tracker.hud
    self.frame:ClearAllPoints()
    self.frame:SetPoint(
        hud.point or "CENTER",
        UIParent,
        hud.relativePoint or "CENTER",
        hud.x or 0,
        hud.y or 95
    )
end

function TrackerHUD:ApplySettings()
    if not self.frame or not EC.state.dbReady then
        return
    end

    local hud = EC.db.tracker.hud
    self.frame:SetScale(hud.scale or 1.0)
    self.frame:SetAlpha(hud.opacity or 0.92)
    self.frame:SetFrameStrata(hud.strata or "HIGH")
    self.frame:EnableMouse(hud.locked == false)
    self.moveTag:SetShown(hud.locked == false)

    self.title:ClearAllPoints()
    self.count:ClearAllPoints()
    self.status:ClearAllPoints()

    if hud.showIcon then
        self.iconBorder:Show()
        self.frame:SetWidth(218)
        self.title:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 66, -9)
        self.count:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 66, -27)
        self.status:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 66, -55)
        self.title:SetWidth(142)
        self.count:SetWidth(142)
        self.status:SetWidth(142)
    else
        self.iconBorder:Hide()
        self.frame:SetWidth(166)
        self.title:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 14, -9)
        self.count:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 14, -27)
        self.status:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 14, -55)
        self.title:SetWidth(142)
        self.count:SetWidth(142)
        self.status:SetWidth(142)
    end

    self.status:SetShown(hud.showRemaining ~= false)
end

function TrackerHUD:Render(data, preview)
    if not self.frame or not EC.state.dbReady then
        return
    end

    if not EC:CanShowGameplay(preview == true) or EC.db.tracker.hud.enabled == false then
        self.frame:Hide()
        return
    end
    data = data or {}
    local waveIndex = tonumber(data.waveIndex) or 0
    local count = tonumber(data.count) or 0
    local limit = data.limit
    if limit ~= nil then
        limit = tonumber(limit)
    end

    self.title:SetText(waveIndex > 0 and ("梦境吐息 · W" .. waveIndex) or "梦境吐息")
    self.count:SetText(string.format("%d / %s", count, limit ~= nil and tostring(limit) or "-"))

    local r, g, b = 0.28, 1.00, 0.50
    local statusText

    if preview then
        statusText = "记录框预览"
    elseif data.tracking and data.quotaConfirmed == false then
        r, g, b = 1.00, 0.78, 0.20
        self.count:SetText(string.format("已喷 %d 次", count))
        statusText = "配额未确认"
    elseif limit == nil then
        r, g, b = 1.00, 0.78, 0.20
        statusText = "等待静滞"
    elseif limit <= 0 then
        r, g, b = 1.00, 0.28, 0.24
        statusText = "本波配额已预扣完"
    elseif count < limit then
        local remaining = limit - count
        if remaining == 1 then
            r, g, b = 1.00, 0.78, 0.20
        end
        statusText = string.format("剩余 %d 次", remaining)
        if data.fallbackMode then
            statusText = (data.outOfPlan and "超出战术板安排 · " or "安全保护 · ") .. statusText
        end
        if data.armed then
            statusText = "蓄力中 · " .. statusText
        end
    elseif count == limit then
        r, g, b = 1.00, 0.28, 0.24
        statusText = data.fallbackMode and "安全保护 · 剩余 0" or "本波已用完"
    else
        r, g, b = 1.00, 0.12, 0.10
        statusText = "已超出本波安排"
    end

    self.count:SetTextColor(r, g, b, 1.0)
    self.status:SetText(statusText)
    self.status:SetTextColor(r, g, b, 0.96)
    self.accent:SetColorTexture(r, g, b, 1.0)
    self.frame:SetBackdropBorderColor(0.20 + r * 0.12, 0.23 + g * 0.12, 0.28 + b * 0.12, 0.88)
    self.frame:Show()
end

function TrackerHUD:CancelPreview()
    if self.previewTimer then
        self.previewTimer:Cancel()
        self.previewTimer = nil
    end
    self.previewActive = false
end

function TrackerHUD:Update()
    if not self.initialized or not self.frame or not EC.state.dbReady then
        return
    end

    local bossActive = EC.Runtime and EC.Runtime:IsEncounterRunning() or false
    -- A preview started just before the pull must not cover real W1 with the
    -- sample W2 2/4, nor should an unlocked placeholder look like live counts.
    if bossActive then self:CancelPreview() end
    local hud = EC.db.tracker.hud
    if hud.enabled == false or not EC:CanShowGameplay(self.previewActive) then
        self.frame:Hide()
        return
    end
    self:ApplySettings()

    if self.previewActive then
        self:Render({ waveIndex = 2, count = 2, limit = 4, armed = false }, true)
        return
    end

    if hud.enabled == false then
        self.frame:Hide()
        return
    end

    local data = EC.CastTracker and EC.CastTracker:GetHUDData() or nil
    if data and data.sessionActive and data.tracking then
        self:Render(data, false)
        return
    end

    if data and data.sessionActive and data.mode == "MRT_TEST" and not bossActive then
        self:Render({ waveIndex = 0, count = 0, limit = nil, tracking = false }, false)
        return
    end

    if hud.locked == false and not bossActive then
        self:Render({ waveIndex = 2, count = 2, limit = 4, armed = false }, true)
        return
    end

    self.frame:Hide()
end

function TrackerHUD:ShowPreview(duration)
    if EC.Runtime and EC.Runtime:IsEncounterRunning() then
        print("|cffffc857[奶龙打地鼠]|r 首领战进行中不显示示例预览，保留当前实际记录。")
        return
    end
    if not self.initialized then
        return
    end

    if self.previewTimer then
        self.previewTimer:Cancel()
        self.previewTimer = nil
    end

    self.previewActive = true
    self:Update()

    self.previewTimer = C_Timer.NewTimer(duration or 3.0, function()
        TrackerHUD.previewActive = false
        TrackerHUD.previewTimer = nil
        TrackerHUD:Update()
    end)
end

function TrackerHUD:SetLocked(locked)
    if not EC.state.dbReady then
        return
    end

    if locked == false and InCombatLockdown and InCombatLockdown() then
        print("|cffff7777[奶龙打地鼠]|r 战斗中不能解锁记录框。")
        return
    end

    if locked then
        self:SavePosition()
    end

    EC.db.tracker.hud.locked = locked and true or false
    self:Update()
end

function TrackerHUD:ResetPosition()
    if not EC.state.dbReady then
        return
    end

    local hud = EC.db.tracker.hud
    hud.point = "CENTER"
    hud.relativePoint = "CENTER"
    hud.x = 0
    hud.y = 95
    self:RestorePosition()
    self:ShowPreview(3.0)
end

function TrackerHUD:CenterHorizontally()
    if not self.frame or not EC.state.dbReady then return end
    local _, centerY = self.frame:GetCenter()
    local _, parentCenterY = UIParent:GetCenter()
    if not centerY or not parentCenterY then return end
    local scale = self.frame:GetEffectiveScale()
    local parentScale = UIParent:GetEffectiveScale()
    if not scale or scale <= 0 or not parentScale then return end
    -- GetCenter is in this frame's scaled units. Convert the parent's center
    -- into the same units; otherwise changing X also changes Y at 70%/150%.
    local yOffset = centerY - parentCenterY * parentScale / scale
    local hud = EC.db.tracker.hud
    hud.point, hud.relativePoint, hud.x, hud.y = "CENTER", "CENTER", 0, yOffset
    self.frame:ClearAllPoints()
    self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, yOffset)
    -- Preserve fractional Y instead of rounding it away for this operation.
    self:ShowPreview(3.0)
end

function TrackerHUD:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true

    local frame = CreateFrame("Frame", "EvokerCueTrackerHUD", UIParent, "BackdropTemplate")
    frame:SetSize(218, 76)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.025, 0.030, 0.040, 0.92)
    frame:SetBackdropBorderColor(0.23, 0.27, 0.32, 0.88)
    frame:Hide()

    self.frame = frame

    self.accent = frame:CreateTexture(nil, "ARTWORK")
    self.accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    self.accent:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    self.accent:SetWidth(3)

    self.iconBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    self.iconBorder:SetSize(44, 44)
    self.iconBorder:SetPoint("LEFT", frame, "LEFT", 11, 0)
    self.iconBorder:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    self.iconBorder:SetBackdropColor(0.01, 0.01, 0.01, 0.95)
    self.iconBorder:SetBackdropBorderColor(0.25, 0.28, 0.32, 0.95)

    self.icon = self.iconBorder:CreateTexture(nil, "ARTWORK")
    self.icon:SetPoint("TOPLEFT", self.iconBorder, "TOPLEFT", 2, -2)
    self.icon:SetPoint("BOTTOMRIGHT", self.iconBorder, "BOTTOMRIGHT", -2, 2)
    self.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    self.icon:SetTexture(GetSpellTextureSafe(DREAM_BREATH_ID) or FALLBACK_ICON)

    self.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.title:SetTextColor(0.90, 0.93, 0.97, 1.0)
    self.title:SetJustifyH("LEFT")

    self.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    self.count:SetJustifyH("LEFT")

    self.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.status:SetJustifyH("LEFT")

    self.moveTag = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.moveTag:SetPoint("BOTTOM", frame, "TOP", 0, 7)
    self.moveTag:SetText("拖动 奶龙打地鼠记录框")
    self.moveTag:SetTextColor(1.00, 0.78, 0.20, 1.0)
    self.moveTag:Hide()

    frame:SetScript("OnDragStart", function(selfFrame)
        if EC.db.tracker.hud.locked then
            return
        end

        if InCombatLockdown and InCombatLockdown() then
            print("|cffff7777[奶龙打地鼠]|r 战斗中不能移动记录框。")
            return
        end

        selfFrame:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
        TrackerHUD:SavePosition()
    end)

    self:RestorePosition()
    self:ApplySettings()
    self:Update()
end
