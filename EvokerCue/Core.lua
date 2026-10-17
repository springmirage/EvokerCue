local addonName, EC = ...

_G.EvokerCue = EC

EC.ADDON_NAME = addonName
EC.TITLE = "EvokerCue"
EC.DISPLAY_NAME = "奶龙打地鼠"
EC.DISPLAY_SUBTITLE = "EvokerCue · 奶龙个人技能轴提醒"
EC.VERSION = "0.8.14"
EC.RELEASE_LABEL = "正式版"

EC.defaults = {
    enabled = true,
    autoRefresh = true,
    debug = false,
    diagnostics = { enabled = true },
    timeline = { planSource = "MRT_RAID", customAliases = {} },
    raidaryPlan = { text = "" },
    heartFire = { enabled = false },

    runtime = {
        -- Keep the legacy saved key to preserve the user's raid-scope toggle.
        -- Since 0.8.6 it covers all three supported 12.1 raids.
        onlyVenomousAbyss = true,
        combatOnly = true,
    },

    sound = {
        enabled = true,
        key = "raid_warning",
        channel = "Master",
    },

    voice = {
        enabled = true,
        backend = "TTS",
        tts = { voice = "AUTO", rate = 0, volume = 100 },
        normalEnabled = true,
        correctionEnabled = true,
        channel = "Master",
    },

    migration = {
        sbgImported = false,
    },

    identity = {
        useCustomName = false,
        customName = "",
    },

    panel = {
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        strata = "FULLSCREEN_DIALOG",
    },

    reminder = {
        enabled = true,
        leadTime = 3.0,
        postHold = 0.9,
        earlyWarningThreshold = 10.0,
        maxRows = 5,
        locked = true,
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 185,
        scale = 1.0,
        opacity = 0.94,
        strata = "HIGH",
        emergencyStrata = "DIALOG",
    },

    tracker = {
        hud = {
            enabled = true,
            locked = true,
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 95,
            scale = 1.0,
            opacity = 0.92,
            strata = "HIGH",
            showIcon = true,
            showRemaining = true,
        },
    },
}

EC.state = {
    dbReady = false,
    result = nil,
    noteText = "",
    noteHash = "",
    noteLength = 0,
    mrtAvailable = false,
    mrtNamespace = nil,
    lastRefreshReason = "尚未读取",
    lastRefreshAt = nil,
    lastIdentitySignature = nil,
    identity = nil,
    logs = {},
}

-- Never serialize, compare, or index protected event values on Retail 12.x.
function EC:IsSecret(value)
    return issecretvalue and issecretvalue(value) or false
end

-- Retail cast-bar IDs are opaque strings on current clients, numbers on older
-- clients. Preserve the type; coercion can falsely identify unrelated casts.
function EC:ReadCastBarID(value)
    if self:IsSecret(value) then return nil, "RESTRICTED" end
    if value == nil then return nil, "MISSING" end
    local kind = type(value)
    if kind == "string" then
        if value == "" then return nil, "INVALID" end
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil, "INVALID" end
    else return nil, "INVALID" end
    return value, "READABLE"
end

function EC:SafeText(value)
    if self:IsSecret(value) then return "<restricted>" end
    local kind = type(value)
    if kind == "table" then return "<table>" end
    if value == nil then return "-" end
    return tostring(value)
end
function EC:CanShowGameplay(preview)
    if not self.state.dbReady or not self.db.enabled then return false end
    if self.Runtime and not self.Runtime:IsZoneAllowed() then return false end
    if preview then return true end
    return not self.db.runtime.combatOnly or
        (self.Runtime and (self.Runtime.encounterActive or self.Runtime.combatActive)) or false
end

local function Trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$") or ""
end

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function AddCandidate(list, seen, value, source)
    value = Trim(value)
    if value == "" or seen[value] then
        return
    end

    seen[value] = true
    table.insert(list, {
        value = value,
        source = source,
    })
end

local function NormalizeRealmName(realm)
    realm = Trim(realm)
    if realm == "" then
        return ""
    end
    return realm:gsub("%s+", "")
end

function EC:GetGamePlayerIdentity()
    local shortName = ""
    local realmName = ""
    local className = ""
    local classFile = ""
    local role = "NONE"

    if UnitFullName then
        local name, realm = UnitFullName("player")
        shortName = Trim(name)
        realmName = Trim(realm)
    end

    if shortName == "" and UnitName then
        local name, realm = UnitName("player")
        shortName = Trim(name)
        realmName = Trim(realm)
    end

    if realmName == "" and GetNormalizedRealmName then
        realmName = Trim(GetNormalizedRealmName())
    end

    if realmName == "" and GetRealmName then
        realmName = Trim(GetRealmName())
    end

    if UnitClass then
        local localizedClass, englishClass = UnitClass("player")
        className = Trim(localizedClass)
        classFile = Trim(englishClass):upper()
    end

    if UnitGroupRolesAssigned then
        role = tostring(UnitGroupRolesAssigned("player") or "NONE"):upper()
    end
    if role == "" or role == "NONE" then
        local specIndex = GetSpecialization and GetSpecialization() or nil
        if specIndex and GetSpecializationRole then
            role = tostring(GetSpecializationRole(specIndex) or "NONE"):upper()
        end
    end

    local normalizedRealm = NormalizeRealmName(realmName)
    local fullName = shortName
    if shortName ~= "" and normalizedRealm ~= "" then
        fullName = shortName .. "-" .. normalizedRealm
    end

    return {
        shortName = shortName,
        realmName = realmName,
        normalizedRealm = normalizedRealm,
        fullName = fullName,
        className = className,
        classFile = classFile,
        role = role,
    }
end

function EC:BuildPlayerIdentity()
    local game = self:GetGamePlayerIdentity()
    local candidates = {}
    local seen = {}
    local mode = "AUTO"

    if self.state.dbReady
        and self.db.identity.useCustomName == true
        and Trim(self.db.identity.customName) ~= ""
    then
        mode = "CUSTOM"
        AddCandidate(candidates, seen, self.db.identity.customName, "CUSTOM")
    else
        -- Full character-realm first, then realm-less character name.
        AddCandidate(candidates, seen, game.fullName, "FULL")
        AddCandidate(candidates, seen, game.shortName, "SHORT")
    end

    local signatureParts = { mode, game.classFile or "", game.role or "" }
    for _, candidate in ipairs(candidates) do
        table.insert(signatureParts, candidate.value)
    end

    return {
        mode = mode,
        game = game,
        candidates = candidates,
        signature = table.concat(signatureParts, "\031"),
    }
end

function EC:RefreshPlayerIdentity()
    self.state.identity = self:BuildPlayerIdentity()
    return self.state.identity
end

function EC:GetPlayerIdentity()
    if not self.state.identity then
        return self:RefreshPlayerIdentity()
    end
    return self.state.identity
end

function EC:SetUseCustomName(value)
    if not self.state.dbReady then
        return
    end
    self.db.identity.useCustomName = value and true or false
    self:RefreshPlayerIdentity()
end

function EC:SetCustomName(value)
    if not self.state.dbReady then
        return
    end
    self.db.identity.customName = Trim(value)
    self:RefreshPlayerIdentity()
end


EC.SOUND_CHOICES = {
    { key = "raid_warning", label = "团本警告", soundKit = "RAID_WARNING" },
    { key = "alarm_warning", label = "警报提示", soundKit = "ALARM_CLOCK_WARNING_3" },
    { key = "ready_check", label = "就绪确认", soundKit = "READY_CHECK" },
}

EC.SOUND_CHANNELS = {
    { key = "Master", label = "主音量" },
    { key = "SFX", label = "音效" },
    { key = "Dialog", label = "对话" },
}

EC.UI_LEVEL_CHOICES = {
    { key = "LOW", label = "低" },
    { key = "MEDIUM", label = "中" },
    { key = "HIGH", label = "高" },
    { key = "DIALOG", label = "很高" },
    { key = "FULLSCREEN_DIALOG", label = "最高" },
}

local function FindChoice(list, key)
    for _, item in ipairs(list or {}) do
        if item.key == key then
            return item
        end
    end
    return list and list[1] or nil
end

function EC:GetSoundChoice()
    return FindChoice(self.SOUND_CHOICES, self.db and self.db.sound and self.db.sound.key)
end

function EC:GetSoundChannel()
    return FindChoice(self.SOUND_CHANNELS, self.db and self.db.sound and self.db.sound.channel)
end

function EC:PlayAlertSound(force)
    if not self.state.dbReady or not self.db.sound then
        return
    end
    if not self.db.enabled then
        if force then print("|cffffc857[奶龙打地鼠]|r 插件总开关已关闭，请先开启再测试声音。") end
        return
    end
    if not force and self.Runtime and not self.Runtime:IsZoneAllowed() then return end
    if not force and not self.db.sound.enabled then
        return
    end

    local sound = self:GetSoundChoice()
    local channel = self:GetSoundChannel()
    if not sound or not SOUNDKIT or not PlaySound then
        return
    end

    local soundID = SOUNDKIT[sound.soundKit]
    if soundID then
        PlaySound(soundID, channel and channel.key or "Master")
    end
end

function EC:InitializeDB()
    if type(EvokerCueDB) ~= "table" then
        EvokerCueDB = {}
    end

    local game = self:GetGamePlayerIdentity()

    -- Alpha 1 migration: it stored a mandatory playerName. Preserve it only when
    -- it is genuinely different from the current character's automatic names.
    local legacyName = Trim(EvokerCueDB.playerName)
    if type(EvokerCueDB.identity) ~= "table" then
        EvokerCueDB.identity = {}
    end
    if EvokerCueDB.identity.useCustomName == nil
        and EvokerCueDB.identity.customName == nil
        and legacyName ~= ""
        and legacyName ~= game.shortName
        and legacyName ~= game.fullName
    then
        EvokerCueDB.identity.useCustomName = true
        EvokerCueDB.identity.customName = legacyName
    end

    ApplyDefaults(EvokerCueDB, self.defaults)
    self.db = EvokerCueDB

    -- First adoption selects the newly requested default for existing users.
    -- Subsequent loads preserve an explicit switch back to the bundled pack.
    if self.db.migration.ttsBackendDefault ~= true then
        self.db.voice.backend = "TTS"
        self.db.migration.ttsBackendDefault = true
    end
    if self.db.voice.backend ~= "TTS" and self.db.voice.backend ~= "OGG" then self.db.voice.backend = "TTS" end

    -- 0.8.4 compatibility: the old single MRT source now maps explicitly to
    -- MRT current/team note. Keep the version unchanged; only the source key is
    -- migrated so existing users retain the same behavior after updating.
    if self.db.timeline and self.db.timeline.planSource == "MRT" then
        self.db.timeline.planSource = "MRT_RAID"
    end

    -- Promote only the former default settings-window strata once.
    -- Keep HUD strata, positions, false toggles and all subsequent user choices.
    if self.db.migration.panelForegroundBeta3 ~= true then
        if self.db.panel.strata == "DIALOG" then
            self.db.panel.strata = "FULLSCREEN_DIALOG"
        end
        self.db.migration.panelForegroundBeta3 = true
    end

    -- If the old counter addon is still enabled on this first upgrade, copy the
    -- player's familiar display/run settings once. EvokerCue remains the only
    -- database used afterward.
    if self.db.migration.sbgImported ~= true
        and type(_G.StasisBreathGuardDB) == "table"
    then
        local old = _G.StasisBreathGuardDB
        if old.onlyVenomousAbyss ~= nil then self.db.runtime.onlyVenomousAbyss = old.onlyVenomousAbyss and true or false end
        if old.combatOnly ~= nil then self.db.runtime.combatOnly = old.combatOnly and true or false end
        if old.sound ~= nil then self.db.sound.enabled = old.sound and true or false end
        if type(old.soundKey) == "string" then self.db.sound.key = old.soundKey end
        if type(old.soundChannel) == "string" then self.db.sound.channel = old.soundChannel end

        local hud = self.db.tracker.hud
        if old.locked ~= nil then hud.locked = old.locked and true or false end
        if type(old.point) == "string" then hud.point = old.point end
        if type(old.relativePoint) == "string" then hud.relativePoint = old.relativePoint end
        if type(old.x) == "number" then hud.x = old.x end
        if type(old.y) == "number" then hud.y = old.y end
        if type(old.scale) == "number" then hud.scale = old.scale end
        if type(old.opacity) == "number" then hud.opacity = old.opacity end
        if old.showIcon ~= nil then hud.showIcon = old.showIcon and true or false end
        if old.showRemaining ~= nil then hud.showRemaining = old.showRemaining and true or false end

        self.db.migration.sbgImported = true
    end

    self.db.reminder.leadTime = math.max(0.5, math.min(10.0, tonumber(self.db.reminder.leadTime) or 3.0))
    self.db.reminder.postHold = math.max(0.2, math.min(3.0, tonumber(self.db.reminder.postHold) or 0.9))
    self.db.reminder.earlyWarningThreshold = math.max(5.0, math.min(15.0, tonumber(self.db.reminder.earlyWarningThreshold) or 10.0))
    self.db.reminder.maxRows = math.max(3, math.min(8, math.floor((tonumber(self.db.reminder.maxRows) or 5) + 0.5)))
    self.db.reminder.scale = math.max(0.70, math.min(1.50, tonumber(self.db.reminder.scale) or 1.0))
    self.db.reminder.opacity = math.max(0.40, math.min(1.00, tonumber(self.db.reminder.opacity) or 0.94))

    self.db.tracker.hud.scale = math.max(0.70, math.min(1.50, tonumber(self.db.tracker.hud.scale) or 1.0))
    self.db.tracker.hud.opacity = math.max(0.40, math.min(1.00, tonumber(self.db.tracker.hud.opacity) or 0.92))

    -- Player settings do not expose internal diagnostic switches.
    self.db.debug = false

    self.state.dbReady = true
    self:RefreshPlayerIdentity()

    if self.Diagnostics and self.Diagnostics.Initialize then
        self.Diagnostics:Initialize()
    end
end

function EC:FormatClock(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then
        seconds = 0
    end

    local tenths = math.floor(seconds * 10 + 0.5) / 10
    local minutes = math.floor(tenths / 60)
    local secondPart = tenths - minutes * 60
    local nearestInteger = math.floor(secondPart + 0.5)

    if math.abs(secondPart - nearestInteger) < 0.001 then
        if nearestInteger >= 60 then
            minutes = minutes + 1
            nearestInteger = 0
        end
        return string.format("%d:%02d", minutes, nearestInteger)
    end

    return string.format("%d:%04.1f", minutes, secondPart)
end

function EC:Log(message, ...)
    local text
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, tostring(message), ...)
        text = ok and formatted or tostring(message)
    else
        text = tostring(message)
    end

    local stamp = date and date("%H:%M:%S") or "--:--:--"
    table.insert(self.state.logs, 1, stamp .. "  " .. text)
    while #self.state.logs > 60 do
        table.remove(self.state.logs)
    end

    if self.Diagnostics and self.Diagnostics.initialized and self.Diagnostics.RecordLog then
        self.Diagnostics:RecordLog(text)
    end

    if self.state.dbReady and self.db.debug then
        print("|cff52d6a0[EvokerCue]|r " .. text)
    end
end

function EC:GetDiagnosticText()
    local result = self.state.result
    local identity = self:GetPlayerIdentity()
    local gameName = identity.game.fullName ~= "" and identity.game.fullName or identity.game.shortName

    local candidateNames = {}
    for _, candidate in ipairs(identity.candidates or {}) do
        table.insert(candidateNames, candidate.value)
    end

    local lines = {
        "EvokerCue " .. self.VERSION,
        "战术板来源：" .. (self.PlanSources and self.PlanSources.GetSelectedLabel and self.PlanSources:GetSelectedLabel() or "MRT当前方案（团队）"),
        "来源状态：" .. tostring(self.state.sourceInfo and self.state.sourceInfo.statusText or "尚未读取"),
        "命名空间：" .. tostring(self.state.mrtNamespace or "-"),
        "当前战术板字符数：" .. tostring(self.state.noteLength or 0),
        "当前游戏角色：" .. tostring(gameName ~= "" and gameName or "-"),
        "识别方式：" .. (identity.mode == "CUSTOM" and "自定义" or "自动"),
        "匹配候选：" .. (#candidateNames > 0 and table.concat(candidateNames, " / ") or "-"),
        "实际匹配：" .. tostring(result and result.matchedPlayerName or "-"),
        "最近刷新：" .. tostring(self.state.lastRefreshAt or "-") .. " / " .. tostring(self.state.lastRefreshReason or "-"),
    }

    if result then
        table.insert(lines, "解析状态：" .. tostring(result.statusText or result.status or "-"))
        table.insert(lines, "匹配角色时间行：" .. tostring(result.stats and result.stats.playerTimedLines or 0))
        table.insert(lines, "识别技能事件：" .. tostring(#(result.events or {})))
        table.insert(lines, "静滞波次：" .. tostring(result.waveQuotaText or "-"))
        table.insert(lines, "跳过阶段格式：" .. tostring(result.stats and result.stats.phaseLinesSkipped or 0))
        table.insert(lines, "未识别本人技能行：" .. tostring(result.stats and result.stats.unrecognizedPlayerLines or 0))
    end

    if self.Timeline and self.Timeline.GetDiagnosticLines then
        table.insert(lines, "")
        for _, line in ipairs(self.Timeline:GetDiagnosticLines()) do
            table.insert(lines, line)
        end
    end

    if self.CastTracker and self.CastTracker.GetDiagnosticLines then
        table.insert(lines, "")
        for _, line in ipairs(self.CastTracker:GetDiagnosticLines()) do
            table.insert(lines, line)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "最近日志：")
    for index = 1, math.min(16, #self.state.logs) do
        table.insert(lines, self.state.logs[index])
    end

    return table.concat(lines, "\n")
end

function EC:RefreshCurrentNote(reason, force, announce)
    if (self.Runtime and self.Runtime.encounterActive) or (InCombatLockdown and InCombatLockdown()) then
        if announce then print("|cffffc857[奶龙打地鼠]|r 本场使用开怪时的战术板；修改将在下次开怪生效，不重置当前记录。") end
        return false
    end
    if not self.state.dbReady or not self.MRTReader or not self.Parser then
        return false
    end

    local identity = self:RefreshPlayerIdentity()
    local noteText, info = self.PlanSources:GetCurrentNote(identity)
    noteText = noteText or ""
    info = info or {}

    local noteHash = self.PlanSources:HashText(noteText, info)
    self.state.sourceInfo = info

    self.state.mrtAvailable = info.available == true
    self.state.mrtNamespace = info.namespace
    self.state.noteLength = #noteText

    if not force
        and noteHash == self.state.noteHash
        and identity.signature == self.state.lastIdentitySignature
    then
        return false
    end

    self.state.noteText = noteText
    self.state.noteHash = noteHash
    self.state.lastIdentitySignature = identity.signature
    self.state.lastRefreshReason = reason or "未知"
    self.state.lastRefreshAt = date and date("%H:%M:%S") or "刚刚"

    self.state.result = self.PlanSources:BuildResult(noteText, identity, info)

    local result = self.state.result
    if self.PlanGuard then self.PlanGuard:AnnouncePlan(result, noteHash, false) end
    self:Log(
        "战术板读取完成：模式=%s，匹配=%s，事件=%d，波次=%s",
        identity.mode,
        result and (result.matchedPlayerName or "-") or "-",
        result and #(result.events or {}) or 0,
        result and (result.waveQuotaText or "-") or "-"
    )

    if self.UI and self.UI.Refresh then
        self.UI:Refresh()
    end

    if announce then
        if result and result.ok then
            print(string.format(
                "|cff52d6a0[奶龙打地鼠]|r 已读取当前战术板：匹配 |cffffffff%s|r，%d 条技能安排，静滞波次 %s。",
                result.matchedPlayerName
                    or (identity.game and (identity.game.fullName ~= "" and identity.game.fullName or identity.game.shortName))
                    or "当前角色",
                #(result.events or {}),
                result.waveQuotaText or "-"
            ))
        else
            print("|cffffc857[奶龙打地鼠]|r 当前战术板没有识别到你的个人时间轴，请打开 /evc 查看。")
        end
    end

    return true
end

function EC:SetEnabled(enabled)
    if not self.state.dbReady then
        return
    end

    self.db.enabled = enabled and true or false
    if self.HeartFireMonitor then self.HeartFireMonitor:ApplySettings() end
    if not self.db.enabled then
        if self.Voice then self.Voice:Stop(true) end
        if self.CastTracker then self.CastTracker:ClearRecentStasisHistory("插件关闭") end
        if self.Timeline then
            self.Timeline:Stop("插件已关闭")
        end
        if self.CastTracker then
            self.CastTracker:EndSession("插件已关闭")
        end
    end

    if self.AlertUI and self.AlertUI.RefreshVisibility then
        self.AlertUI:RefreshVisibility()
    end
    if self.TrackerHUD and self.TrackerHUD.Update then
        self.TrackerHUD:Update()
    end
    if self.Runtime and self.Runtime.RefreshAfterSettings then
        self.Runtime:RefreshAfterSettings()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= addonName then
            return
        end

        EC:InitializeDB()
        return
    end

    if event == "PLAYER_LOGIN" then
        if not EC.state.dbReady then
            EC:InitializeDB()
        end

        if EC.Voice and EC.Voice.Initialize then
            EC.Voice:Initialize()
        end

        if EC.AlertUI and EC.AlertUI.Initialize then
            EC.AlertUI:Initialize()
        end

        if EC.TrackerHUD and EC.TrackerHUD.Initialize then
            EC.TrackerHUD:Initialize()
        end

        if EC.CastTracker and EC.CastTracker.Initialize then
            EC.CastTracker:Initialize()
        end

        if EC.Timeline and EC.Timeline.Initialize then
            EC.Timeline:Initialize()
        end

        if EC.UI and EC.UI.Initialize then
            EC.UI:Initialize()
        end

        if EC.PlanSources then EC.PlanSources:Initialize() end
        if EC.HeartFireMonitor then EC.HeartFireMonitor:Initialize() end

        if EC.Runtime and EC.Runtime.Initialize then
            EC.Runtime:Initialize()
        end

        if EC.MRTButton and EC.MRTButton.Initialize then
            EC.MRTButton:Initialize()
        end

        C_Timer.After(0.8, function()
            EC:RefreshCurrentNote("登录读取", true, false)
        end)

        if not EC.state.welcomePrinted then
            EC.state.welcomePrinted = true
            print("|cff52d6a0[奶龙打地鼠]|r 欢迎使用！作者：|cffffffff韶光逍珑|r。输入 |cffffffff/evc|r 打开设置。反馈使用问题、交流功能建议，欢迎加入 QQ 群：|cffffffff251935247|r。")
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(1.0, function()
            EC:RefreshCurrentNote("进入世界", false, false)
        end)
        return
    end

    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ROLES_ASSIGNED" then
        local unit = ...
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit and unit ~= "player" then
            return
        end
        C_Timer.After(0.2, function()
            EC:RefreshPlayerIdentity()
            if EC.db and EC.db.autoRefresh then
                EC:RefreshCurrentNote("角色职责更新", true, false)
            end
        end)
        return
    end

end)

SLASH_EVOKERCUE1 = "/evc"
SLASH_EVOKERCUE2 = "/evokercue"

SlashCmdList.EVOKERCUE = function(message)
    local command = tostring(message or ""):match("^%s*(.-)%s*$"):lower()

    if command == "log" then
        if EC.Diagnostics and EC.Diagnostics.PrintUploadHelp then
            EC.Diagnostics:PrintUploadHelp()
        end
        return
    end

    if command == "reset" or command == "prepull" then
        if EC.Runtime and EC.Runtime.ResetPrepullState then
            EC.Runtime:ResetPrepullState("手动命令清空预铺", true)
        else
            print("|cffff7777[奶龙打地鼠]|r 预铺清理暂时不可用。")
        end
        return
    end

    if EC.UI and EC.UI.Toggle then
        EC.UI:Toggle()
    else
        print("|cffff7777[奶龙打地鼠]|r 设置面板暂时无法打开。")
    end
end
