local addonName, EC = ...

local AlertUI = {}
EC.AlertUI = AlertUI

AlertUI.lastDiagnosticRenderCount = -1

AlertUI.initialized = false
AlertUI.frame = nil
AlertUI.rows = {}
AlertUI.overflowRow = nil
AlertUI.lastEntries = nil
AlertUI.emergencyEntry = nil
AlertUI.emergencyTimer = nil
AlertUI.emergencyGeneration = 0

local ROW_WIDTH = 392
local ROW_HEIGHT = 25
local ROW_GAP = 2

local EARLY_COLOR = { 0.24, 0.76, 1.00 }
local LATE_COLOR = { 1.00, 0.78, 0.18 }
local CRITICAL_COLOR = { 1.00, 0.10, 0.08 }

local function FetchTexture(spellID)
    if spellID and C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and texture then
            return texture
        end
    end
    return 134400
end

local function SetBackdrop(frame, background, border)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(unpack(background))
    frame:SetBackdropBorderColor(unpack(border))
end

local function FormatCountdown(remaining)
    remaining = tonumber(remaining) or 0
    if remaining > 0.04 then
        return string.format("%.1fs", math.max(0, remaining))
    end
    if remaining >= -0.05 then
        return "0.0s"
    end
    return "现在"
end

function AlertUI:CreateRow(index)
    local row = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })

    row.accent = row:CreateTexture(nil, "ARTWORK")
    row.accent:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.accent:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.accent:SetWidth(3)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Fixed columns.  Never use inserted spaces for alignment: every status string
    -- (1.0s / 再等10.0s / 已晚10.0s / 取消蓄力！) occupies the same 104px slot.
    row.countdown = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.countdown:SetPoint("LEFT", row, "LEFT", 36, 0)
    row.countdown:SetWidth(104)
    row.countdown:SetJustifyH("RIGHT")
    row.countdown:SetWordWrap(false)

    row.skill = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.skill:SetPoint("LEFT", row, "LEFT", 152, 0)
    row.skill:SetWidth(158)
    row.skill:SetJustifyH("LEFT")
    row.skill:SetWordWrap(false)

    row.quota = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.quota:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.quota:SetWidth(62)
    row.quota:SetJustifyH("RIGHT")
    row.quota:SetWordWrap(false)

    self.rows[index] = row
    return row
end

function AlertUI:GetRow(index)
    return self.rows[index] or self:CreateRow(index)
end

function AlertUI:CreateOverflowRow()
    if self.overflowRow then
        return self.overflowRow
    end

    local row = CreateFrame("Frame", nil, self.frame, "BackdropTemplate")
    row:SetSize(ROW_WIDTH, 21)
    SetBackdrop(row, { 0.025, 0.030, 0.040, 0.86 }, { 0.20, 0.23, 0.28, 0.75 })

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("CENTER")
    row.text:SetTextColor(0.68, 0.72, 0.78, 1)

    self.overflowRow = row
    return row
end

function AlertUI:ApplyPosition()
    if not self.frame or not EC.state.dbReady then
        return
    end

    local db = EC.db.reminder
    self.frame:ClearAllPoints()
    self.frame:SetPoint(
        db.point or "CENTER",
        UIParent,
        db.relativePoint or "CENTER",
        db.x or 0,
        db.y or 185
    )
end

function AlertUI:SavePosition()
    if not self.frame or not EC.state.dbReady then
        return
    end

    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    EC.db.reminder.point = point or "CENTER"
    EC.db.reminder.relativePoint = relativePoint or "CENTER"
    EC.db.reminder.x = math.floor((x or 0) + 0.5)
    EC.db.reminder.y = math.floor((y or 0) + 0.5)
end

function AlertUI:ApplySettings()
    if not self.frame or not EC.state.dbReady then
        return
    end

    self.frame:SetScale(EC.db.reminder.scale or 1.0)
    self.frame:SetAlpha(EC.db.reminder.opacity or 0.94)
    self.frame:SetFrameStrata(
        self.emergencyEntry
            and (EC.db.reminder.emergencyStrata or "DIALOG")
            or (EC.db.reminder.strata or "HIGH")
    )
    self.frame:EnableMouse(not EC.db.reminder.locked)

    if EC.db.reminder.locked then
        self.frame:SetScript("OnEnter", nil)
        self.frame:SetScript("OnLeave", nil)
    end

    self:RefreshVisibility()
end

function AlertUI:SetLocked(locked)
    if not EC.state.dbReady then
        return
    end

    EC.db.reminder.locked = locked and true or false
    self:ApplySettings()
end

function AlertUI:ResetPosition()
    if not EC.state.dbReady then
        return
    end

    EC.db.reminder.point = "CENTER"
    EC.db.reminder.relativePoint = "CENTER"
    EC.db.reminder.x = 0
    EC.db.reminder.y = 185
    self:ApplyPosition()
    self:RefreshVisibility()
end

function AlertUI:HorizontalCenter()
    if not self.frame or not EC.state.dbReady then return end
    local _, centerY = self.frame:GetCenter()
    local _, parentCenterY = UIParent:GetCenter()
    if not centerY or not parentCenterY then return end
    local scale = self.frame:GetEffectiveScale()
    local parentScale = UIParent:GetEffectiveScale()
    if not scale or scale <= 0 or not parentScale then return end
    local yOffset = centerY - parentCenterY * parentScale / scale
    local settings = EC.db.reminder
    settings.point, settings.relativePoint, settings.x, settings.y = "CENTER", "CENTER", 0, yOffset
    self.frame:ClearAllPoints()
    self.frame:SetPoint("CENTER", UIParent, "CENTER", 0, yOffset)
end

function AlertUI:FormatQuota(event)
    if event.emergency and event.quotaText then
        return tostring(event.quotaText)
    end

    if event.skillKey == "DREAM_BREATH" then
        if event.quotaReliable == false then return "—" end
        local index = event.displayBreathIndex or event.breathIndex
        local limit = event.displayBreathLimit or event.breathLimit
        if index and limit then
            return string.format("%d/%d", index, limit)
        end
    end
    return ""
end

function AlertUI:RenderRow(row, entry)
    local event = entry.event
    local state = entry.state or "NORMAL"
    local color = event.color or { 1, 1, 1 }

    if state == "EARLY" then
        color = EARLY_COLOR
    elseif state == "LATE" or state == "BALL_LATE" then
        color = LATE_COLOR
    end

    row.icon:SetTexture(event.texture or FetchTexture(event.spellID))

    if event.emergency then
        row.countdown:SetText(event.statusText or "取消蓄力！")
    elseif state == "BALL_LATE" then
        row.countdown:SetText("溜溜球晚了")
    elseif state == "BALL_CASTING" then
        row.countdown:SetText("施法中")
    elseif state == "EARLY" then
        row.countdown:SetText(string.format("再等%.1fs", math.max(0, tonumber(entry.remaining) or 0)))
    elseif state == "LATE" then
        row.countdown:SetText(string.format("已晚%.1fs", math.abs(math.min(0, tonumber(entry.remaining) or 0))))
    else
        row.countdown:SetText(FormatCountdown(entry.remaining))
    end

    row.skill:SetText(event.skillName or event.skillKey or "技能")
    row.quota:SetText(self:FormatQuota(event))

    row.accent:SetColorTexture(color[1] or 1, color[2] or 1, color[3] or 1, 1)
    row.countdown:SetTextColor(color[1] or 1, color[2] or 1, color[3] or 1, 1)
    row.skill:SetTextColor(0.94, 0.96, 0.98, 1)
    row.quota:SetTextColor(color[1] or 1, color[2] or 1, color[3] or 1, 1)

    row:SetBackdropColor(
        0.018 + (color[1] or 0) * 0.045,
        0.022 + (color[2] or 0) * 0.035,
        0.030 + (color[3] or 0) * 0.025,
        0.91
    )
    row:SetBackdropBorderColor(
        0.14 + (color[1] or 0) * 0.12,
        0.16 + (color[2] or 0) * 0.10,
        0.19 + (color[3] or 0) * 0.08,
        0.82
    )
end

local function PlayEmergencySound()
    if EC.PlayAlertSound then
        EC:PlayAlertSound(false)
    end
end

function AlertUI:ShowEmergency(text, quotaText, duration, playSound, tone)
    if not self.initialized then
        return
    end

    self.emergencyGeneration = self.emergencyGeneration + 1
    local generation = self.emergencyGeneration

    if self.emergencyTimer then
        self.emergencyTimer:Cancel()
        self.emergencyTimer = nil
    end

    local parser = EC.Parser
    local breathDef = parser and parser:GetSkillDefinition("DREAM_BREATH") or nil
    self.frame:SetFrameStrata(EC.db.reminder.emergencyStrata or "DIALOG")

    local noticeColor = CRITICAL_COLOR
    if tone == "CAUTION" then
        noticeColor = LATE_COLOR
    elseif tone == "EARLY" then
        noticeColor = EARLY_COLOR
    end

    self.emergencyEntry = {
        remaining = 0,
        state = tone == "CAUTION" and "LATE" or (tone == "EARLY" and "EARLY" or "CRITICAL"),
        event = {
            emergency = true,
            statusText = text or "取消蓄力！",
            skillKey = "DREAM_BREATH",
            skillName = "梦境吐息",
            quotaText = quotaText or "",
            spellID = breathDef and breathDef.primaryID or 355936,
            texture = parser and parser:GetSkillTexture("DREAM_BREATH") or FetchTexture(355936),
            color = noticeColor,
        },
    }

    if playSound then
        PlayEmergencySound()
    end

    if duration and duration > 0 then
        self.emergencyTimer = C_Timer.NewTimer(duration, function()
            if AlertUI.emergencyGeneration == generation then
                AlertUI:ClearEmergency()
            end
        end)
    end

    self:RefreshVisibility()
end

-- A separate owner avoids clearing/replacing the Dream Breath emergency.
-- This path is text-only: no generic sound and no speech queue entry.
function AlertUI:ShowBallEmergency()
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return end
    if not self.initialized then return end
    self.ballEmergencyEntry = { remaining = 0, state = "CRITICAL", event = {
        emergency = true, statusText = "取消读条！", skillKey = "BALL", skillName = "溜溜球",
        quotaText = "", spellID = 373861,
        texture = EC.Parser and EC.Parser:GetSkillTexture("BALL"), color = CRITICAL_COLOR,
    } }
    self:RefreshVisibility()
end

function AlertUI:ClearBallEmergency()
    if not self.ballEmergencyEntry then return end
    self.ballEmergencyEntry = nil
    self:RefreshVisibility()
end

function AlertUI:ClearEmergency()
    self.emergencyGeneration = self.emergencyGeneration + 1
    if self.emergencyTimer then
        self.emergencyTimer:Cancel()
        self.emergencyTimer = nil
    end
    self.emergencyEntry = nil
    if self.frame and EC.state.dbReady then
        self.frame:SetFrameStrata(EC.db.reminder.strata or "HIGH")
    end
    self:RefreshVisibility()
end

function AlertUI:Render(entries)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then self.ballEmergencyEntry = nil end
    if not self.initialized or not self.frame then
        return
    end

    entries = entries or {}
    self.lastEntries = entries

    if EC.state.dbReady then
        self.frame:SetFrameStrata(
            (self.emergencyEntry or self.ballEmergencyEntry)
                and (EC.db.reminder.emergencyStrata or "DIALOG")
                or (EC.db.reminder.strata or "HIGH")
        )
    end

    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    if self.overflowRow then
        self.overflowRow:Hide()
    end

    if not EC:CanShowGameplay(EC.Timeline and EC.Timeline.source == "DENSE_PREVIEW") then
        self.frame:Hide()
        return
    end

    local renderEntries = {}
    if self.emergencyEntry then
        table.insert(renderEntries, self.emergencyEntry)
    end
    if self.ballEmergencyEntry then table.insert(renderEntries, self.ballEmergencyEntry) end

    -- Turning ordinary timeline reminders off must NOT suppress the red safety
    -- warning. Emergency remains independent from reminder.enabled.
    if EC.db.reminder.enabled then
        for _, entry in ipairs(entries) do
            if not EC.Features or EC.Features:SkillEnabled(entry.event.skillKey) then
                table.insert(renderEntries, entry)
            end
        end
    end

    if #renderEntries == 0 then
        if self.lastDiagnosticRenderCount ~= 0 then
            self.lastDiagnosticRenderCount = 0
            EC:Log(
                "提醒界面渲染：count=0，reminderEnabled=%s，strata=%s",
                tostring(EC.db.reminder.enabled),
                tostring(EC.db.reminder.strata or "HIGH")
            )
        end

        if EC.db.reminder.enabled
            and not EC.db.reminder.locked
            and not (EC.Timeline and EC.Timeline.active)
        then
            self:ShowPlacementPreview()
        else
            self.frame:Hide()
        end
        return
    end

    if self.lastDiagnosticRenderCount ~= #renderEntries then
        self.lastDiagnosticRenderCount = #renderEntries
        EC:Log(
            "提醒界面渲染：count=%d，reminderEnabled=%s，strata=%s，emergency=%s",
            #renderEntries,
            tostring(EC.db.reminder.enabled),
            tostring((self.emergencyEntry or self.ballEmergencyEntry) and (EC.db.reminder.emergencyStrata or "DIALOG") or (EC.db.reminder.strata or "HIGH")),
            tostring(self.emergencyEntry ~= nil or self.ballEmergencyEntry ~= nil)
        )
    end

    local maxRows = EC.db.reminder.maxRows or 5
    local displayed = math.min(#renderEntries, maxRows)
    local yOffset = 0

    for index = 1, displayed do
        local row = self:GetRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOP", self.frame, "TOP", 0, -yOffset)
        self:RenderRow(row, renderEntries[index])
        row:Show()
        yOffset = yOffset + ROW_HEIGHT + ROW_GAP
    end

    if #renderEntries > maxRows then
        local overflow = self:CreateOverflowRow()
        overflow:ClearAllPoints()
        overflow:SetPoint("TOP", self.frame, "TOP", 0, -yOffset)
        overflow.text:SetText(string.format("另有 %d 条同时提醒", #renderEntries - maxRows))
        overflow:Show()
        yOffset = yOffset + 21 + ROW_GAP
    end

    self.frame:SetSize(ROW_WIDTH, math.max(ROW_HEIGHT, yOffset - ROW_GAP))
    self.frame:Show()
end

function AlertUI:GetPlacementEntries()
    local parser = EC.Parser
    local breathDef = parser and parser:GetSkillDefinition("DREAM_BREATH") or nil
    local texture = parser and parser:GetSkillTexture("DREAM_BREATH") or 134400
    local color = breathDef and breathDef.color or { 0.25, 1, 0.48 }

    local function BreathEvent(index, limit)
        return {
            skillKey = "DREAM_BREATH",
            skillName = "梦境吐息",
            spellID = breathDef and breathDef.primaryID or 355936,
            texture = texture,
            color = color,
            breathIndex = index,
            breathLimit = limit,
        }
    end

    return {
        { remaining = 1.0, state = "NORMAL", event = BreathEvent(3, 4) },
        { remaining = 10.0, state = "EARLY", event = BreathEvent(3, 4) },
        { remaining = -10.0, state = "LATE", event = BreathEvent(3, 4) },
    }
end

function AlertUI:ShowPlacementPreview()
    -- Unlocked placement samples are not real reminders, particularly the
    -- sample "已晚10.0s". Never show them in an active encounter.
    if (EC.Runtime and EC.Runtime:IsEncounterRunning()) or not EC:CanShowGameplay(false) then
        self.frame:Hide()
        return
    end
    local wasLocked = EC.db.reminder.locked
    local entries = self:GetPlacementEntries()

    -- Render directly to avoid recursive empty-entry handling.
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    if self.overflowRow then
        self.overflowRow:Hide()
    end

    local yOffset = 0
    for index, entry in ipairs(entries) do
        local row = self:GetRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOP", self.frame, "TOP", 0, -yOffset)
        self:RenderRow(row, entry)
        row:Show()
        yOffset = yOffset + ROW_HEIGHT + ROW_GAP
    end

    self.frame:SetSize(ROW_WIDTH, yOffset - ROW_GAP)
    self.frame:Show()
end

function AlertUI:Clear()
    if not self.initialized then
        return
    end

    self.lastEntries = nil
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    if self.overflowRow then
        self.overflowRow:Hide()
    end

    self:RefreshVisibility()
end

function AlertUI:RefreshVisibility()
    if not self.initialized or not self.frame or not EC.state.dbReady then
        return
    end

    if not EC:CanShowGameplay(EC.Timeline and EC.Timeline.source == "DENSE_PREVIEW") then
        self.frame:Hide()
        return
    end

    if self.emergencyEntry or self.ballEmergencyEntry then
        self:Render(self.lastEntries or {})
        return
    end

    if EC.db.reminder.enabled
        and EC.Timeline
        and EC.Timeline.active
        and self.lastEntries
        and #self.lastEntries > 0
    then
        self:Render(self.lastEntries)
        return
    end

    if EC.db.reminder.enabled and not EC.db.reminder.locked then
        self:ShowPlacementPreview()
    else
        self.frame:Hide()
    end
end

function AlertUI:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true

    local frame = CreateFrame("Frame", "EvokerCueAlertStack", UIParent)
    frame:SetSize(ROW_WIDTH, ROW_HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:Hide()

    frame:SetScript("OnDragStart", function(self)
        if EC.db.reminder.locked then
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            print("|cffff7777[奶龙打地鼠]|r 战斗中不调整提醒区位置。")
            return
        end
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        AlertUI:SavePosition()
    end)

    self.frame = frame
    self:ApplyPosition()
    self:ApplySettings()
end
