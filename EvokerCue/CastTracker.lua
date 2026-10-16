local addonName, EC = ...

local CastTracker = {}
EC.CastTracker = CastTracker

local STASIS_ID = 370537
local STASIS_RELEASE_ID = 370562
local STASIS_RELEASE_CAST_IDS = { [370562] = true, [370564] = true }
local DREAM_BREATH_IDS = {
    [355936] = true,
    [382614] = true,
}

local SUCCEEDED_SKILLS = {
    [363534] = "REWIND",
    [384089] = "REWIND",
    [374227] = "ZEPHYR",
    [406732] = "SPATIAL_PARADOX",
    [406789] = "SPATIAL_PARADOX",
    [374968] = "TIME_SPIRAL",
}

local STASIS_RELEASE_FALLBACK_WINDOW = 35.0

CastTracker.initialized = false
CastTracker.sessionActive = false
CastTracker.sessionMode = "IDLE"
CastTracker.snapshot = nil
CastTracker.tracking = false
CastTracker.currentWaveIndex = 0
CastTracker.currentWaveLimit = nil
CastTracker.currentWavePlannedLimit = nil
CastTracker.currentWaveDebtApplied = 0
CastTracker.breathCount = 0
CastTracker.breathArmed = false
CastTracker.armedOverQuota = false
CastTracker.armGeneration = 0
CastTracker.armStartedAt = nil
CastTracker.sessionStartTime = nil
CastTracker.lastAcceptedInitialStasisAt = nil
CastTracker.recentInitialStasisAt = nil
CastTracker.recentInitialStasisReleased = false
CastTracker.recentInitialStasisGUID = nil
CastTracker.recentInitialStasisBarID = nil
CastTracker.prepullStasisAt = nil
CastTracker.prepullStasisEligible = false
CastTracker.prepullDreamBreathCount = 0
CastTracker.prepullDreamBreathArmed = false
CastTracker.prepullDreamBreathArmStartedAt = nil
CastTracker.lastWaveMatchDelta = nil
CastTracker.borrowedThisWave = 0
CastTracker.borrowedTotal = 0
CastTracker.lastConsumedToken = nil
CastTracker.safetyMode = false
CastTracker.lastStopReason = "尚未运行"
CastTracker.eventFrame = nil

local function Now()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return GetTime()
end

local function IsDreamBreath(spellID)
    return spellID ~= nil and DREAM_BREATH_IDS[spellID] == true
end

local function PlayBuiltInEmergencySound()
    if EC.PlayAlertSound then
        EC:PlayAlertSound(false)
    end
end

local function ReadIdentityField(value, kind)
    if EC:IsSecret(value) then return nil, "RESTRICTED" end
    if value == nil then return nil, "MISSING" end
    if type(value) ~= kind then return nil, "INVALID" end
    if kind == "string" and value == "" then return nil, "INVALID" end
    if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
        return nil, "INVALID"
    end
    return value, "READABLE"
end

local function ReadEmpowerIdentity(castGUID, spellID, castBarID)
    local guid, guidState = ReadIdentityField(castGUID, "string")
    local bar, barState = ReadIdentityField(castBarID, "number")
    local spell, spellState = ReadIdentityField(spellID, "number")
    return { castGUID = guid, castBarID = bar, spellID = spell,
        guidState = guidState, barState = barState, spellState = spellState }
end

local function MatchEmpowerIdentity(active, received)
    if not active then return "NO_ACTIVE" end
    -- Every readable contradiction wins, even if the other key agrees.
    if active.castBarID ~= nil and received.castBarID ~= nil and active.castBarID ~= received.castBarID then
        return "MISMATCH", "BAR_ID"
    end
    if active.castGUID and received.castGUID and active.castGUID ~= received.castGUID then
        return "MISMATCH", "GUID"
    end
    if active.spellID and received.spellID and active.spellID ~= received.spellID then
        return "MISMATCH", "SPELL_ID"
    end
    if active.castBarID ~= nil and received.castBarID ~= nil then return "MATCH", "BAR_ID" end
    if active.castGUID and received.castGUID then return "MATCH", "GUID" end
    -- Generation associates local state with a token; it cannot prove a STOP's identity.
    return "UNVERIFIABLE", "NO_COMMON_ID"
end

function CastTracker:LogEmpower(event, active, received, matchResult, complete, reason)
    -- Optional diagnostics must never throw into the cast observer. All identities
    -- reaching this function contain only checked, non-secret scalar values.
    pcall(function()
        local id = received or active or {}
        local record = { event = event, castGUID = id.castGUID, castBarID = id.castBarID,
            spellID = id.spellID, guidState = id.guidState, barState = id.barState, spellState = id.spellState,
            activeGUID = active and active.castGUID, activeBarID = active and active.castBarID,
            generation = active and active.generation, startedAt = active and active.startedAt,
            token = active and (type(active.token) == "table" and active.token.tokenIndex or active.finalTokenIndex), matchResult = matchResult,
            complete = complete, reason = reason, wave = self.currentWaveIndex, count = self.breathCount }
        if EC.Diagnostics and EC.Diagnostics.RecordCast then EC.Diagnostics:RecordCast(record) end
        if EC.Diagnostics and EC.Diagnostics.Event then
            EC.Diagnostics:Event(event, string.format("gen=%s guid=%s(%s) bar=%s(%s) spell=%s(%s) match=%s reason=%s",
                tostring(record.generation), tostring(id.castGUID), tostring(id.guidState),
                tostring(id.castBarID), tostring(id.barState), tostring(id.spellID), tostring(id.spellState),
                tostring(matchResult), tostring(reason)))
        end
    end)
end

-- Optional observers run only after the ledger is consistent. Do not use
-- Diagnostics:Run here: its generic recovery changes combat quota/armed state.
local function NotifyEmpowerEffect(func, ...)
    local ok, err = pcall(func, ...)
    if not ok then
        pcall(function()
            if EC.Diagnostics and EC.Diagnostics.Event then
                EC.Diagnostics:Event("EMPOWER_NOTIFY_ERROR", tostring(err))
            end
        end)
    end
end
CastTracker.NotifyEmpowerEffect = NotifyEmpowerEffect

-- Shared success/cancel/rejection cleanup, with no UI, audio or diagnostics.
local function CloseEmpowerState(self, empower)
    local token = empower.token
    local owned = type(token) == "table" and token.empowerGeneration == empower.generation
    local timeline = EC.Timeline
    local warning = owned and timeline and timeline.earlyWarningToken == token
    if owned then
        token.reserved = nil
        token.empowerGeneration = nil
        token.earlyWarningActive = false
    end
    if warning then
        timeline.earlyWarningToken = nil
        timeline.earlyWarningCastGUID = nil
        timeline.earlyWarningCastBarID = nil
    end
    if self.activeEmpower == empower then
        self.activeEmpower = nil
        self.breathToken = nil
        self.breathArmed = false
        self.armedOverQuota = false
        self.armStartedAt = nil
    end
    if self.prepullEmpower == empower then
        self.prepullEmpower = nil
        self.prepullDreamBreathArmed = false
        self.prepullDreamBreathArmStartedAt = nil
    end
    empower.finalTokenIndex = type(token) == "table" and token.tokenIndex or nil
    empower.token = nil
    empower.closed = true
    self.lastClosedEmpower = empower
    return warning and token or nil
end

-- Called only after STOP identity/completion validation. Prepare everything
-- first, then synchronously commit plain addon-owned tables without observers.
function CastTracker:FinalizeEmpowerStop(empower, complete)
    if not empower or empower.closed
        or (empower ~= self.activeEmpower and empower ~= self.prepullEmpower) then
        return nil, "EMPOWER_ALREADY_CLOSED"
    end
    local token = empower.token
    local knownSlot = empower.knownSlot
    local live = empower == self.activeEmpower and self.sessionActive and self.tracking
    if token ~= nil and type(token) ~= "table" then return nil, "INVALID_TOKEN_STATE" end
    if live and (token ~= self.breathToken or (token and
        (token.reserved ~= true or token.empowerGeneration ~= empower.generation))) then
        return nil, "EMPOWER_TOKEN_OWNER_MISMATCH"
    end
    local commit = { empower = empower, complete = complete, live = live,
        overQuota = self.armedOverQuota, generation = empower.generation,
        empowerTime = Now() - empower.startedAt }
    if live and complete and token then
        if not self.quotaConfirmed or not EC.Timeline or self.snapshot ~= EC.Timeline.snapshot then
            return nil, "TOKEN_QUOTA_UNCONFIRMED"
        end
        local prepared, reason = EC.Timeline:PrepareDreamBreathTokenCommit(token, self.currentWaveIndex,
            "实际梦境吐息释放", false, empower.generation)
        if not prepared then return nil, reason end
        commit.tokenCommit = prepared
    end
    if live and complete then
        commit.count = self.breathCount + 1
        commit.borrowedThisWave = self.borrowedThisWave + (commit.tokenCommit and commit.tokenCommit.borrowed and 1 or 0)
        commit.borrowedTotal = self.borrowedTotal + (commit.tokenCommit and commit.tokenCommit.borrowed and 1 or 0)
    end
    if self.prepullEmpower == empower and self.prepullDreamBreathArmed then
        commit.prepull = true
        if complete and self:IsPrepullPackageUsable(Now()) then
            commit.prepullCount = (self.prepullDreamBreathCount or 0) + 1
            commit.prepullCasts = self.prepullCasts or {}
            if #commit.prepullCasts < 100 then
                commit.prepullRecord = { at = Now(), startedAt = empower.startedAt,
                    castGUID = empower.castGUID, castBarID = empower.castBarID }
            end
        end
    end

    -- CORE COMMIT. No clock reads, formatting, selection, callbacks or pcall.
    commit.warningToken = CloseEmpowerState(self, empower)
    if commit.tokenCommit then EC.Timeline:CommitDreamBreathToken(commit.tokenCommit) end
    if complete and knownSlot and empower.knownSnapshot == self.snapshot
        and self.snapshot == EC.Timeline.snapshot and self.sessionActive and not knownSlot.consumed then
        knownSlot.consumed = true; knownSlot.reminderClosed = true
        commit.knownSlot = knownSlot
    end
    if commit.count then
        self.breathCount = commit.count
        self.lastConsumedToken = commit.tokenCommit and token or nil
        self.borrowedThisWave = commit.borrowedThisWave
        self.borrowedTotal = commit.borrowedTotal
    end
    if commit.prepullCount then
        self.prepullDreamBreathCount = commit.prepullCount
        self.prepullCasts = commit.prepullCasts
        if commit.prepullRecord then self.prepullCasts[#self.prepullCasts + 1] = commit.prepullRecord end
    end
    empower.completed = complete
    return commit
end

function CastTracker:RejectEmpowerCommit(empower, reason)
    -- A corrupt/foreign token is never consumed and counts/debt stay unchanged.
    local warning = CloseEmpowerState(self, empower)
    empower.commitRejected = reason
    if self.prepullStasisEligible then self.prepullEmpowerUncertain = true end
    local timeline = self.sessionActive and self.tracking and EC.Timeline
        and self.snapshot == EC.Timeline.snapshot and EC.Timeline
    local invalidation
    if self.sessionActive and self.tracking then
        self.quotaConfirmed = false
        self.quotaReason = reason
        if timeline then invalidation = timeline:InvalidateRecord(reason, self.currentWaveIndex, true) end
    end
    -- Rejection cleanup and quota invalidation are complete before reporting.
    self:LogEmpower("EMPOWER_COMMIT_REJECTED", empower, nil, "REJECTED", nil, reason)
    if timeline then NotifyEmpowerEffect(timeline.NotifyRecordInvalidated, timeline, invalidation) end
    self:NotifyEmpowerStop({ empower = empower, generation = empower.generation,
        warningToken = warning, rejected = reason })
    NotifyEmpowerEffect(function()
        if EC.PlanGuard then EC.PlanGuard:Warn("EMPOWER_COMMIT_REJECTED",
            "绿喷 Token 账本状态异常，本次未提交，已暂停本波配额纠错；请在战斗结束后用 /evc log 提交反馈。") end
    end)
end

function CastTracker:NotifyEmpowerStop(commit)
    if commit.knownSlot then
        NotifyEmpowerEffect(function() if EC.Voice then EC.Voice:CancelOwner(commit.knownSlot) end end)
        NotifyEmpowerEffect(EC.Timeline.RenderNow, EC.Timeline)
    end
    if commit.tokenCommit then
        NotifyEmpowerEffect(EC.Timeline.NotifyDreamBreathTokenCommit, EC.Timeline, commit.tokenCommit)
    elseif commit.warningToken then
        NotifyEmpowerEffect(function()
            if EC.Voice then EC.Voice:CancelOwner(commit.warningToken, "CORRECTION") end
        end)
        NotifyEmpowerEffect(EC.Timeline.RenderNow, EC.Timeline)
    end
    NotifyEmpowerEffect(function() if EC.Voice then EC.Voice:CancelCastWarning() end end)
    NotifyEmpowerEffect(function()
        if commit.prepull then
            EC:Log("预开怪绿喷结束：complete=%s，缓存=%d，generation=%d",
                tostring(commit.complete), self.prepullDreamBreathCount, commit.generation)
        end
        if commit.live then
            EC:Log("绿喷结算：complete=%s W%d count=%d quota=%s generation=%d token=%s borrowed=%s empowerTime=%.2f",
                tostring(commit.complete), self.currentWaveIndex, self.breathCount,
                tostring(self.currentWaveLimit or "未确认"), commit.generation,
                commit.tokenCommit and tostring(commit.tokenCommit.token.tokenIndex) or "无",
                tostring(commit.tokenCommit and commit.tokenCommit.borrowed or false), commit.empowerTime)
        end
    end)
    NotifyEmpowerEffect(function()
        if commit.live and commit.complete and EC.Diagnostics and EC.Diagnostics.RecordCast then
            local tokenCommit = commit.tokenCommit
            local consumed = tokenCommit and tokenCommit.token
            EC.Diagnostics:RecordCast({ event = "DREAM_BREATH_RELEASE", wave = self.currentWaveIndex,
                count = self.breathCount, quota = self.currentWaveLimit, generation = commit.generation,
                token = consumed and consumed.tokenIndex, tokenWave = consumed and consumed.waveIndex,
                borrowed = tokenCommit and tokenCommit.borrowed or false, quotaConfirmed = self.quotaConfirmed })
        end
    end)
    NotifyEmpowerEffect(function()
        if not EC.AlertUI then return end
        local tokenCommit = commit.tokenCommit
        if tokenCommit and tokenCommit.borrowed and self:HasReliableQuota() then
            EC.AlertUI:ShowEmergency("已预扣下一波", "W" .. tokenCommit.token.waveIndex .. " -1", 1.15, false, "CAUTION")
        elseif commit.complete and commit.overQuota and self:HasReliableQuota() then
            EC.AlertUI:ShowEmergency("已超额", tostring(self.breathCount) .. "/" .. tostring(self.currentWaveLimit), 1.15, false, "CAUTION")
        else EC.AlertUI:ClearEmergency() end
    end)
    NotifyEmpowerEffect(self.NotifyChanged, self)
end

function CastTracker:ReleaseEmpowerToken(empower, complete)
    local token = empower and empower.token
    if token and token.empowerGeneration == empower.generation then
        token.reserved = nil
        token.empowerGeneration = nil
        -- Only the cast which owns the reservation may cancel its correction.
        if EC.Timeline and EC.Timeline.earlyWarningToken == token then
            EC.Timeline:HandleDreamBreathEmpowerStop(empower.castGUID, empower.castBarID, complete == true)
        end
    end
    if empower then empower.token = nil end
end

function CastTracker:BindEmpowerToken(empower, token)
    if not empower or empower ~= self.activeEmpower or empower.closed then return end
    empower.token = token
    self.breathToken = token
    if token then token.empowerGeneration = empower.generation end
end

function CastTracker:ClearArm(reason, preserveIdentity)
    local empower = self.activeEmpower
    if self.breathArmed then
        EC:Log(
            "绿喷蓄力状态清除：reason=%s，generation=%s",
            tostring(reason or "未知"),
            tostring(self.armGeneration)
        )
    end

    self.breathArmed = false
    self.armedOverQuota = false
    self.armStartedAt = nil
    if empower then
        self:ReleaseEmpowerToken(empower, reason == "released_successfully")
        if not preserveIdentity then
            empower.closed = true
            self.lastClosedEmpower = empower
        end
    elseif self.breathToken and not self.breathToken.empowerGeneration then
        self.breathToken.reserved = nil
    end
    self.activeEmpower = nil
    self.breathToken = nil
    if EC.Voice and EC.Voice.CancelCastWarning then EC.Voice:CancelCastWarning() end
end

function CastTracker:ClearPrepullEmpower(reason)
    local empower = self.prepullEmpower
    self.prepullEmpower = nil
    self.prepullDreamBreathArmed = false
    self.prepullDreamBreathArmStartedAt = nil
    if empower then
        if empower == self.activeEmpower then self:ClearArm(reason)
        else self:ReleaseEmpowerToken(empower, false) end
        empower.closed = true
        self.lastClosedEmpower = empower
    end
end

function CastTracker:AbandonEmpower(reason)
    local empower = self.activeEmpower or self.prepullEmpower
    if empower then self:LogEmpower("EMPOWER_ABANDONED", empower, nil, "ABANDON", nil, reason) end
    self:ClearPrepullEmpower(reason)
    self:ClearArm(reason)
    if EC.AlertUI then EC.AlertUI:ClearEmergency() end
end

function CastTracker:InvalidateEmpowerQuota(reason)
    if self.prepullStasisEligible then self.prepullEmpowerUncertain = true end
    if not self.sessionActive or not self.tracking then return end
    -- Preserve actual wave, counts and debt. Only confidence is lost.
    self.quotaConfirmed = false
    self.quotaReason = reason
    if EC.Timeline and self.snapshot == EC.Timeline.snapshot then
        EC.Timeline:InvalidateRecord(reason, self.currentWaveIndex)
    end
    if EC.AlertUI then EC.AlertUI:ClearEmergency() end
    if EC.PlanGuard then EC.PlanGuard:Warn("EMPOWER_IDENTITY_UNCONFIRMED",
        "当前绿喷施法回报无法可靠配对，已暂停本波配额纠错；实际次数继续记录，请在战斗结束后用 /evc log 提交反馈。") end
    self:NotifyChanged()
end

function CastTracker:DetachPrepullEmpower()
    local empower = self.prepullEmpower
    if not empower then return nil end
    self.prepullEmpower = nil
    self.prepullDreamBreathArmed = false
    self.prepullDreamBreathArmStartedAt = nil
    if self.activeEmpower == empower then self:ClearArm("prepull_handoff", true) end
    return empower
end

function CastTracker:RestorePrepullEmpower(empower)
    if not empower or empower.closed or not self.prepullStasisEligible or self.recentInitialStasisReleased then return end
    self.prepullEmpower = empower
    self.prepullDreamBreathArmed = true
    self.prepullDreamBreathArmStartedAt = empower.startedAt
    self:LogEmpower("EMPOWER_HANDOFF", empower, nil, "PRESERVED")
end

function CastTracker:ClearPrepullPackage(reason)
    self:ClearPrepullEmpower(reason)
    self.prepullEmpowerUncertain = nil
    local hadState = self.prepullStasisEligible or self.prepullStasisAt ~= nil
    self.prepullStasisAt = nil
    self.prepullStasisEligible = false
    self.prepullDreamBreathCount = 0
    self.prepullDreamBreathArmed = false
    self.prepullDreamBreathArmStartedAt = nil
    self.prepullCasts = {}
    self.prepullAuraPhase = nil
    self.prepullAuraSeen = false
    self.prepullAuraUnknown = false
    self.prepullMissingSince = nil
    self.prepullReadyExpiresAt = nil
    if self.prepullTicker then self.prepullTicker:Cancel(); self.prepullTicker = nil end
    if hadState then EC:Log("清理预开怪 W1 暂存：%s", tostring(reason or "未指定")) end
end

function CastTracker:CreatePrepullStasisCandidate(castAt)
    self:ClearPrepullPackage("新的静滞候选")
    self.prepullStasisAt = tonumber(castAt) or Now()
    self.prepullStasisEligible = true
    self.prepullAuraPhase = "CAST_OBSERVED"
    self.prepullCasts = {}
    EC:Log("预开怪 W1 候选建立：静滞 time=%.3f", self.prepullStasisAt)
    if C_Timer and C_Timer.NewTicker then
        self.prepullTicker = C_Timer.NewTicker(0.2, function()
            EC.Diagnostics:Run("预铺状态检查", self.CheckPrepullAura, self)
        end)
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.05, function()
        EC.Diagnostics:Run("预铺状态检查", self.CheckPrepullAura, self)
    end) end
end

function CastTracker:IsPrepullPackageUsable(atTime)
    if not self.prepullStasisEligible or not self.prepullStasisAt or self.recentInitialStasisReleased then
        return false, nil
    end
    if EC.Runtime and EC.Runtime.encounterActive then return false, nil end
    if EC.Runtime and not EC.Runtime:CanRun() then return false, nil end
    local age = (tonumber(atTime) or Now()) - self.prepullStasisAt
    return age >= 0, age -- No arbitrary age limit on a still-valid prepull lifecycle.
end

function CastTracker:CapturePrepullDreamBreathStart(empower)
    local usable, age = self:IsPrepullPackageUsable(Now())
    if not usable then
        return false
    end

    self.prepullEmpower = empower
    self.prepullDreamBreathArmed = true
    self.prepullDreamBreathArmStartedAt = empower.startedAt

    EC:Log(
        "预开怪绿喷开始蓄力：静滞后 %.2fs，已缓存成功绿喷=%d，guid=%s，bar=%s",
        tonumber(age) or 0,
        self.prepullDreamBreathCount or 0,
        tostring(empower.castGUID),
        tostring(empower.castBarID)
    )
    return true
end

function CastTracker:BridgeCompletedPrepullDreamBreaths(tokens)
    local count = math.max(0, math.floor(tonumber(self.prepullDreamBreathCount) or 0))
    local commits, seen = {}, {}
    for i = 1, count do
        local token = tokens and tokens[i]
        if self.quotaConfirmed and token and EC.Timeline then
            local commit, reason = EC.Timeline:PrepareDreamBreathTokenCommit(token, self.currentWaveIndex,
                "预开怪绿喷继承", true)
            if seen[token] then commit, reason = nil, "DUPLICATE_PREPULL_TOKEN" end
            if not commit then
                self.quotaConfirmed = false
                self.quotaReason = reason
                local invalidation = EC.Timeline:InvalidateRecord(reason, self.currentWaveIndex, true)
                NotifyEmpowerEffect(EC.Timeline.NotifyRecordInvalidated, EC.Timeline, invalidation)
                self:LogEmpower("EMPOWER_COMMIT_REJECTED", nil, nil, "PREPULL", nil, reason)
                return 0
            end
            commits[#commits + 1] = commit
            seen[token] = true
        end
    end
    local total = self.breathCount + count
    for _, commit in ipairs(commits) do EC.Timeline:CommitDreamBreathToken(commit) end
    self.breathCount = total
    self.prepullDreamBreathCount = 0
    for _, commit in ipairs(commits) do
        NotifyEmpowerEffect(EC.Timeline.NotifyDreamBreathTokenCommit, EC.Timeline, commit)
    end
    NotifyEmpowerEffect(function()
        EC:Log("继承开怪前绿喷：W%d count=%d quota=%s", self.currentWaveIndex,
            self.breathCount, tostring(self.currentWaveLimit or "未确认"))
    end)
    return count
end

function CastTracker:AdoptOngoingPrepullDreamBreath()
    local empower = self.prepullEmpower
    if not empower or empower.closed or not self.prepullDreamBreathArmed or not self.sessionActive or not self.tracking then
        return false
    end

    local startedAt = self.prepullDreamBreathArmStartedAt
    self.prepullEmpower = nil
    self.prepullDreamBreathArmed = false
    self.prepullDreamBreathArmStartedAt = nil

    self.activeEmpower = empower
    self.breathArmed = true
    self.armStartedAt = startedAt or Now()
    self.armedOverQuota = self:IsOverQuotaBeforeNextBreath()

    EC:Log(
        "继承跨开怪绿喷蓄力：W%d，当前=%d/%s，generation=%d，overQuota=%s",
        self.currentWaveIndex,
        self.breathCount,
        self.currentWaveLimit ~= nil and tostring(self.currentWaveLimit) or "-",
        self.armGeneration,
        tostring(self.armedOverQuota)
    )

    if self.armedOverQuota then
        self:ShowOverQuotaWarning()
    end

    return true
end

function CastTracker:GetWave(index)
    local waves = self.snapshot and self.snapshot.waves
    if type(waves) ~= "table" then
        return nil
    end
    return waves[index]
end

function CastTracker:GetPlannedWaveCount()
    local waves = self.snapshot and self.snapshot.waves
    return type(waves) == "table" and #waves or 0
end

function CastTracker:NotifyChanged()
    self.lastNotifiedQuotaReliable = self:HasReliableQuota()
    if EC.TrackerHUD and EC.TrackerHUD.Update then
        EC.TrackerHUD:Update()
    end

    if EC.UI and EC.UI.RefreshTrackerStatus then
        EC.UI:RefreshTrackerStatus()
    end

    if EC.UI and EC.UI.RefreshRuntime then
        EC.UI:RefreshRuntime()
    end
end

function CastTracker:RefreshQuotaReliability()
    -- Time alone can invalidate a wave without a cast event. The timeline checks
    -- this boolean; only a transition uses the existing UI notification path.
    if self.lastNotifiedQuotaReliable ~= self:HasReliableQuota() then
        self:NotifyChanged()
    end
end

function CastTracker:DismissActiveReminder(skillKey, reason)
    if EC.Timeline and EC.Timeline.DismissActiveEvent then
        EC.Timeline:DismissActiveEvent(skillKey, reason)
    end
end

function CastTracker:CheckPrepullAura()
    if not self.prepullStasisEligible then return end
    -- Only inspect non-secret player auras OUTSIDE combat. Never poll combat auras.
    if EC.Runtime and EC.Runtime.encounterActive then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local api = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if not api then self.prepullAuraUnknown = true; return end
    local ok1, storing = pcall(api, STASIS_ID)
    local ok2, ready = pcall(api, STASIS_RELEASE_ID)
    if not ok1 or not ok2 or EC:IsSecret(storing) or EC:IsSecret(ready) then
        if not self.prepullAuraUnknown then EC:Log("预铺状态暂不可读：保留实际记录，等待确认") end
        self.prepullAuraUnknown = true
        return
    end
    local now = Now()
    local phase = type(ready) == "table" and "READY" or (type(storing) == "table" and "STORING" or "NONE")
    if phase == "NONE" then
        if now - self.prepullStasisAt < 0.75 then return end -- Aura application can follow cast success.
        if not self.prepullAuraSeen then
            self.prepullAuraUnknown = true
            return
        end
        if not self.prepullMissingSince then
            self.prepullMissingSince = now
            return -- Storing -> ready is not a release. Wait for the second sample.
        end
        if now - self.prepullMissingSince >= 0.25 then
            self:ResetPrepullState("战前静滞状态已结束（释放、取消或到期）")
        end
        return
    end
    self.prepullMissingSince = nil
    self.prepullAuraUnknown = false
    self.prepullAuraSeen = true
    self.prepullAuraCheckedAt = now
    if self.prepullAuraPhase ~= phase then
        self.prepullAuraPhase = phase
        EC:Log("预铺状态确认：%s（装满不代表释放，不切波）", phase)
    end
    if phase == "READY" then
        local expires = ready.expirationTime
        if not EC:IsSecret(expires) and type(expires) == "number" and expires > 0 then
            self.prepullReadyExpiresAt = now + math.max(0, expires - GetTime())
        end
    else
        self.prepullReadyExpiresAt = nil
    end
end

function CastTracker:GetPrepullValidity()
    if not self.prepullStasisEligible or not self.prepullStasisAt or self.recentInitialStasisReleased then
        return false, "NO_CANDIDATE"
    end
    if self.prepullReadyExpiresAt and Now() >= self.prepullReadyExpiresAt then
        return false, "READY_EXPIRED"
    end
    if self.prepullMissingSince or self.prepullAuraUnknown then return nil, "STATE_UNCONFIRMED" end
    if self.prepullAuraSeen then return true, self.prepullAuraPhase end
    if Now() - self.prepullStasisAt <= 0.75 then return true, "RECENT_CAST" end
    return nil, "STATE_UNCONFIRMED"
end

function CastTracker:GetPrepullSnapshot()
    local casts = {}
    for _, cast in ipairs(self.prepullCasts or {}) do
        casts[#casts + 1] = { at = cast.at, startedAt = cast.startedAt,
            castGUID = cast.castGUID, castBarID = cast.castBarID }
    end
    local valid, reason = self:GetPrepullValidity()
    return { eligible = self.prepullStasisEligible, stasisAt = self.prepullStasisAt,
        age = self.prepullStasisAt and Now() - self.prepullStasisAt or nil,
        count = self.prepullDreamBreathCount or 0, armed = self.prepullDreamBreathArmed,
        armStartedAt = self.prepullDreamBreathArmStartedAt, phase = self.prepullAuraPhase,
        validity = valid == true and "VALID" or (valid == false and "ENDED" or "UNKNOWN"),
        validityReason = reason, readyExpiresAt = self.prepullReadyExpiresAt, casts = casts }
end

function CastTracker:HasReliableQuota()
    if not self.snapshot then return false end
    if not self.tracking or not self.quotaConfirmed then return false end
    local wave = self:GetWave(self.currentWaveIndex)
    if not wave or wave.runtimeInvalid or wave.quotaReliable ~= true then return false end
    if self.sessionMode == "BOSS" or self.sessionMode == "MRT_TEST" then
        local elapsed = self:GetSessionElapsedAt(Now()) or 0
        if wave.nextStasisTime and elapsed >= wave.nextStasisTime then return false end
    end
    return true
end

function CastTracker:SetUnconfirmed(reason, resetCount, waveHint)
    local oldWave = self.currentWaveIndex or 0
    self.quotaConfirmed = false
    self.quotaReason = reason or "UNCONFIRMED"
    self.safetyMode = false
    self.tracking = true
    self.currentWaveIndex = waveHint or 0
    self.currentWaveLimit = nil
    self.currentWavePlannedLimit = nil
    self.currentWaveDebtApplied = 0
    if resetCount then self.breathCount = 0; self:ClearArm("unmatched_new_stasis") end
    self.borrowedThisWave = 0
    if EC.Timeline and EC.Timeline.active and self.snapshot == EC.Timeline.snapshot then
        EC.Timeline:InvalidateRecord(self.quotaReason, oldWave)
    end
    if EC.AlertUI then EC.AlertUI:ClearEmergency() end
    EC:Log("配额未确认：reason=%s actualWave=%d count=%d", self.quotaReason, self.currentWaveIndex, self.breathCount)
    if EC.PlanGuard then
        EC.PlanGuard:Warn("QUOTA:" .. self.quotaReason,
            "静滞与当前 MRT 波次无法可靠对齐，已暂停这一段的绿喷配额纠错；实际次数继续记录，后续匹配成功时恢复。")
    end
    self:NotifyChanged()
end

function CastTracker:BeginSession(snapshot, mode, startTime)
    self:ClearBallCast("begin_session")
    self.closedBallCasts = {}
    self.closedBallSnapshot = snapshot
    self:ClearPrepullEmpower("begin_session")
    self.sessionActive = true
    self.quotaConfirmed = false
    self.quotaReason = "WAITING_STASIS"
    self.claimedWaves = {}
    self.highestMatchedWave = 0
    self.sessionMode = mode or "UNKNOWN"
    self.snapshot = snapshot
    self.sessionStartTime = tonumber(startTime) or Now()
    self.tracking = false
    self.currentWaveIndex = 0
    self.currentWaveLimit = nil
    self.currentWavePlannedLimit = nil
    self.currentWaveDebtApplied = 0
    self.breathCount = 0
    self.borrowedThisWave = 0
    self.borrowedTotal = 0
    self.lastConsumedToken = nil
    self.lastWaveMatchDelta = nil
    self.safetyMode = false
    self.lastStopReason = "运行中"
    self:ClearArm("begin_session")

    if EC.AlertUI and EC.AlertUI.ClearEmergency then
        EC.AlertUI:ClearEmergency()
    end

    EC:Log(
        "真实施法记录启动：mode=%s，计划波次=%d",
        tostring(self.sessionMode),
        self:GetPlannedWaveCount()
    )

    self:NotifyChanged()
end

function CastTracker:EndSession(reason)
    self:ClearBallCast(reason)
    local wasActive = self.sessionActive

    self.sessionActive = false
    self.quotaConfirmed = false
    self.quotaReason = "IDLE"
    self.claimedWaves = {}
    self.highestMatchedWave = 0
    self.sessionMode = "IDLE"
    self.snapshot = nil
    self.sessionStartTime = nil
    self.tracking = false
    self.currentWaveIndex = 0
    self.currentWaveLimit = nil
    self.currentWavePlannedLimit = nil
    self.currentWaveDebtApplied = 0
    self.breathCount = 0
    self.borrowedThisWave = 0
    self.borrowedTotal = 0
    self.lastConsumedToken = nil
    self.lastWaveMatchDelta = nil
    self.safetyMode = false
    self.lastStopReason = reason or "未知"
    self:ClearArm("end_session")
    self:ClearPrepullEmpower("end_session")

    if EC.AlertUI and EC.AlertUI.ClearEmergency then
        EC.AlertUI:ClearEmergency()
    end

    if wasActive then
        EC:Log("真实施法记录停止：%s", tostring(self.lastStopReason))
    end

    self:NotifyChanged()
end

-- Record real Stasis casts independently from the current encounter session.  This is
-- what lets a Stasis pressed during the pull countdown survive ENCOUNTER_START.
-- A second 370537 inside the fallback window is treated as the Stasis reactivation
-- some Retail clients report with the initial spell id, not as a new wave.
function CastTracker:ObserveInitialStasis(castGUID, castBarID)
    local now = Now()
    if (castGUID ~= nil and castGUID == self.recentInitialStasisGUID)
        or (castGUID == nil and castBarID ~= nil and castBarID == self.recentInitialStasisBarID)
        or (self.lastStasisEventAt and now - self.lastStasisEventAt < 0.08) then
        EC:Log("忽略同一次静滞重复回报")
        return nil, false, false
    end
    self.lastStasisEventAt = now

    if not (EC.Runtime and EC.Runtime.encounterActive) and self.prepullStasisEligible then
        -- Reactivation can report 370537 too, even after a long storage period.
        -- A ready/storing aura transition must confirm its end, not a 35-second guess.
        EC:Log("战前静滞再次回报：等待状态确认，不新建波次")
        self:CheckPrepullAura()
        return nil, false, false
    end

    if self.lastAcceptedInitialStasisAt then
        local elapsed = now - self.lastAcceptedInitialStasisAt
        if elapsed >= 0 and (elapsed <= STASIS_RELEASE_FALLBACK_WINDOW
            or (self.bridgedReadyExpiresAt and now <= self.bridgedReadyExpiresAt + 0.25)) then
            self.recentInitialStasisReleased = true
            self:ClearPrepullPackage("静滞释放回报")
            EC:Log(
                "忽略静滞释放回报：elapsed=%.2f，guid=%s，bar=%s",
                elapsed,
                tostring(castGUID),
                tostring(castBarID)
            )
            return nil, false, true
        end
    end

    self.lastAcceptedInitialStasisAt = now
    self.recentInitialStasisAt = now
    self.recentInitialStasisReleased = false
    self.recentInitialStasisGUID = castGUID
    self.recentInitialStasisBarID = castBarID

    -- Before ENCOUNTER_START, an accepted real Stasis starts a fresh prepull W1
    -- package.  Trash combat is harmless because PLAYER_REGEN_ENABLED clears it.
    if not (EC.Runtime and EC.Runtime.encounterActive) then
        self:CreatePrepullStasisCandidate(now)
    end

    EC:Log(
        "观察到真实静滞：guid=%s，bar=%s，session=%s",
        tostring(castGUID),
        tostring(castBarID),
        tostring(self.sessionMode or "IDLE")
    )

    return now, true, false
end

function CastTracker:ObserveStasisRelease(spellID)
    if self.recentInitialStasisAt then
        self.recentInitialStasisReleased = true
    end
    self.bridgedReadyExpiresAt = nil
    self:ClearPrepullPackage("静滞已释放")
    EC:Log("释放静滞：不切波，spellID=%s", tostring(spellID or STASIS_RELEASE_ID))

    -- Before a Boss starts, releasing Stasis means this prepull attempt is over.
    -- Clear the upper record HUD immediately.  During a Boss this branch is never
    -- taken: Release Stasis must NOT change Wave or Dream Breath count.
    if not (EC.Runtime and EC.Runtime.encounterActive) then
        self:ResetPrepullState("开怪前释放静滞")
    end
end

function CastTracker:ClearRecentStasisHistory(reason)
    self.lastAcceptedInitialStasisAt = nil
    self.recentInitialStasisAt = nil
    self.recentInitialStasisReleased = false
    self.recentInitialStasisGUID = nil
    self.recentInitialStasisBarID = nil
    self.lastStasisEventAt = nil
    self.bridgedReadyExpiresAt = nil
    self:ClearPrepullPackage(reason or "清理静滞跨战记录")
    EC:Log("清理静滞跨战记录：%s", tostring(reason or "未指定"))
end

-- Clear only the pre-boss record state.  This intentionally does NOT stop or
-- rebuild the MRT reminder timeline: upper record HUD and lower reminder module
-- are independent.  Once ENCOUNTER_START is active this operation is forbidden,
-- so death/battle-resurrection can never wipe the current Boss wave.
function CastTracker:ResetPrepullState(reason)
    if EC.Runtime and EC.Runtime.encounterActive then
        EC:Log("拒绝清空预铺：首领战进行中")
        return false, "BOSS_ACTIVE"
    end

    reason = reason or "清空预铺"

    self:ClearRecentStasisHistory(reason)
    self:ClearArm("reset_prepull")

    -- A TEST/COMBAT fallback session may stay alive so the next real Stasis can
    -- immediately start recording again.  Only its pre-boss Wave/counter state is
    -- returned to a clean waiting state.
    if self.sessionMode ~= "BOSS" then
        self.tracking = false
        self.quotaConfirmed = false
        self.quotaReason = "RESET"
        self.claimedWaves = {}
        self.highestMatchedWave = 0
        self.currentWaveIndex = 0
        self.currentWaveLimit = nil
        self.currentWavePlannedLimit = nil
        self.currentWaveDebtApplied = 0
        self.breathCount = 0
        self.borrowedThisWave = 0
        self.borrowedTotal = 0
        self.lastConsumedToken = nil
        self.lastWaveMatchDelta = nil
        self.safetyMode = false
        self.lastStopReason = "预铺已清空"
    end

    if EC.AlertUI and EC.AlertUI.ClearEmergency then
        EC.AlertUI:ClearEmergency()
    end

    EC:Log("预铺记录已清空：%s", tostring(reason))
    self:NotifyChanged()
    return true
end

function CastTracker:GetSessionElapsedAt(absoluteTime)
    if not self.sessionStartTime then
        return nil
    end
    return (tonumber(absoluteTime) or Now()) - self.sessionStartTime
end

-- Wave identity comes from MRT Stasis timestamps, never from "the Nth real Stasis".
-- Only an unambiguous planned Stasis inside the bounded matching window is eligible.
-- Missing a real W2 does not renumber the subsequent MRT W3.
function CastTracker:MatchWaveForElapsed(actualElapsed)
    return EC.PlanGuard:FindWave(self.snapshot, tonumber(actualElapsed) or 0, self.claimedWaves)
end

function CastTracker:ApplyActualWave(waveIndex, actualElapsed, plannedStasisTime, matchDistance, reason)
    if not self.sessionActive then return false end
    local wave = self:GetWave(waveIndex)
    if not wave or wave.mappingReliable == false or (self.claimedWaves or {})[waveIndex]
        or waveIndex < (self.highestMatchedWave or 0) then
        self:SetUnconfirmed("WAVE_MAPPING_REJECTED", true)
        return false
    end
    self.claimedWaves = self.claimedWaves or {}
    self.claimedWaves[waveIndex] = true
    self.highestMatchedWave = math.max(self.highestMatchedWave or 0, waveIndex)
    self.currentWaveIndex = waveIndex
    self.breathCount = 0
    self.borrowedThisWave = 0
    self.tracking = true
    self.lastWaveMatchDelta = (tonumber(actualElapsed) or 0) - wave.stasisTime
    self:ClearArm("new_actual_stasis")
    if EC.AlertUI then EC.AlertUI:ClearEmergency() end
    self.quotaConfirmed = wave.quotaReliable ~= false and (wave.breathLimit or 0) > 0
    self.quotaReason = self.quotaConfirmed and "MATCHED" or "NO_BREATH_QUOTA"
    self.currentWavePlannedLimit = self.quotaConfirmed and wave.breathLimit or nil
    self.currentWaveLimit = self.currentWavePlannedLimit
    self.currentWaveDebtApplied = 0
    self.safetyMode = false
    if EC.Timeline and EC.Timeline.active and EC.Timeline.snapshot == self.snapshot then
        local effective = EC.Timeline:EnterActualWave(waveIndex)
        if self.quotaConfirmed then
            self.currentWaveLimit = effective or self.currentWavePlannedLimit
            self.currentWaveDebtApplied = math.max(0, self.currentWavePlannedLimit - self.currentWaveLimit)
        end
        EC.Timeline:DismissPlannedStasisWave(waveIndex, reason or "实际静滞")
    end
    EC:Log("实际静滞映射：actual=%.2f -> MRT W%d %s，偏差=%+.2fs，配额=%s，预借扣除=%d",
        actualElapsed or 0, waveIndex, EC:FormatClock(wave.stasisTime), self.lastWaveMatchDelta,
        tostring(self.currentWaveLimit or "未确认"), self.currentWaveDebtApplied)
    if not self.quotaConfirmed and EC.PlanGuard then
        EC.PlanGuard:Warn("EMPTY_WAVE:" .. waveIndex,
            "W" .. waveIndex .. " 未提供有效绿喷配额：本波只记录实际次数，不进行超额纠错。")
    end
    self:NotifyChanged()
    return true
end

function CastTracker:AdvanceActualWave(castGUID, castBarID, castAt, reason)
    if not self.sessionActive then return false end
    local elapsed = self:GetSessionElapsedAt(castAt or Now()) or 0
    local wave, planned, distance, rejected = self:MatchWaveForElapsed(elapsed)
    if not wave then
        EC:Log("拒绝静滞映射：actual=%.2f reason=%s closestTime=%s distance=%s", elapsed,
            tostring(rejected), tostring(planned or "-"), tostring(distance or "-"))
        self:SetUnconfirmed(rejected or "NO_MRT_WAVE", true)
        return false
    end
    return self:ApplyActualWave(wave, elapsed, planned, distance, reason)
end

function CastTracker:BridgeRecentPrepullStasis()
    if not self.sessionActive or self.sessionMode ~= "BOSS" then return false end
    local valid, validityReason = self:GetPrepullValidity()
    if valid == false then
        EC:Log("开怪前静滞继承：没有有效预铺 reason=%s", validityReason)
        self:ClearPrepullPackage(validityReason)
        return false
    end
    local castAt = self.prepullStasisAt
    local count, ongoing = self.prepullDreamBreathCount or 0, self.prepullDreamBreathArmed
    local waveIndex, rejected, tokens = EC.PlanGuard:FindOpeningWave(self.snapshot, count, ongoing)
    if self.prepullEmpowerUncertain then rejected = rejected or "EMPOWER_IDENTITY_UNCONFIRMED" end
    local elapsed = self:GetSessionElapsedAt(castAt) or 0
    local applied = false
    if valid and waveIndex then
        local wave = self:GetWave(waveIndex)
        applied = self:ApplyActualWave(waveIndex, elapsed, wave.stasisTime,
            math.abs(elapsed - wave.stasisTime), "开怪前静滞")
    end
    if not applied or rejected or not valid then
        self:SetUnconfirmed(rejected or validityReason or "PREPULL_UNMATCHED", false, applied and waveIndex or nil)
        self.breathCount = 0
        tokens = nil
        if EC.PlanGuard then
            local text = not valid and "预铺实际施法已保留，但静滞状态暂未确认；本段不进行配额纠错。"
                or "已保留战前静滞与 " .. count .. " 次绿喷，但 MRT 开头缺少可对应的静滞或预铺绿喷；不会占用后面的波次。"
            EC.PlanGuard:Warn("PREPULL:" .. tostring(rejected or validityReason), text)
        end
    end
    self.bridgedReadyExpiresAt = self.prepullReadyExpiresAt
    local completed = self:BridgeCompletedPrepullDreamBreaths(tokens)
    local adopted = self:AdoptOngoingPrepullDreamBreath()
    if adopted and self.quotaConfirmed and tokens then
        local token = tokens[completed + 1]
        if token then token.reserved = true end
        self:BindEmpowerToken(self.activeEmpower, token)
    end
    EC:Log("预铺交接完成：age=%.2f state=%s wave=%d count=%d quota=%s ongoing=%s",
        Now() - (castAt or Now()), tostring(validityReason), self.currentWaveIndex,
        self.breathCount, tostring(self.currentWaveLimit or "未确认"), tostring(adopted))
    self:ClearPrepullPackage("已交接本场，不重复继承")
    self:NotifyChanged()
    return true
end

function CastTracker:IsOverQuotaBeforeNextBreath()
    return self:HasReliableQuota() and self.currentWaveLimit ~= nil and self.breathCount >= self.currentWaveLimit
end

function CastTracker:ShowOverQuotaWarning()
    if not self:HasReliableQuota() then return end
    local limit = self.currentWaveLimit or 0
    local quota = string.format("%d/%d", self.breathCount, limit)

    local voicePlayed = false
    if EC.Voice and EC.Voice.PlaySpecial then
        voicePlayed = EC.Voice:PlaySpecial("CANCEL", false, true) and true or false
    end

    if EC.AlertUI and EC.AlertUI.ShowEmergency then
        -- Dedicated cancel voice takes priority; generic warning sound remains fallback.
        EC.AlertUI:ShowEmergency("取消蓄力！", quota, nil, not voicePlayed)
    else
        print(string.format("|cffff3333[奶龙打地鼠]|r 取消蓄力！本波 %s", quota))
        if not voicePlayed then PlayBuiltInEmergencySound() end
    end
end

function CastTracker:HandleEmpowerStart(castGUID, spellID, castBarID)
    local empower = ReadEmpowerIdentity(castGUID, spellID, castBarID)
    if not empower.spellID then
        self:LogEmpower("EMPOWER_START_UNREADABLE", self.activeEmpower or self.prepullEmpower, empower, "UNVERIFIABLE")
        self:AbandonEmpower("unreadable_new_start")
        self:InvalidateEmpowerQuota("EMPOWER_START_UNREADABLE")
        return
    end
    if not IsDreamBreath(empower.spellID) then return end
    local previous = self.activeEmpower or self.prepullEmpower
    if previous then
        local match, key = MatchEmpowerIdentity(previous, empower)
        if match == "MATCH" then
            self:LogEmpower("EMPOWER_START_DUPLICATE", previous, empower, key)
            return
        end
        self:LogEmpower("EMPOWER_REPLACED", previous, empower, match, nil, key)
        self:AbandonEmpower("new_start_replaces_pending")
    end
    self.armGeneration = self.armGeneration + 1
    empower.generation = self.armGeneration
    empower.startedAt = Now()
    self:CapturePrepullDreamBreathStart(empower)
    self:LogEmpower("EMPOWER_START", empower, nil, "ARMED")
    if self.sessionActive and EC.Timeline and self.snapshot == EC.Timeline.snapshot and not self:HasReliableQuota() then
        empower.knownSlot = EC.Timeline:GetKnownBreathSlot(EC.Timeline:GetElapsed())
        empower.knownSnapshot = self.snapshot
        self.activeEmpower = empower
    end
    if not self.sessionActive or not self.tracking then
        EC:Log("绿喷蓄力：未确认静滞记录，guid=%s bar=%s", EC:SafeText(castGUID), EC:SafeText(castBarID))
        return
    end
    self.activeEmpower = empower
    self.breathArmed = true
    self.armStartedAt = empower.startedAt
    self.armedOverQuota = self:IsOverQuotaBeforeNextBreath()
    self.breathToken = nil
    if self:HasReliableQuota() and EC.Timeline and EC.Timeline.active and self.snapshot == EC.Timeline.snapshot then
        self:BindEmpowerToken(empower, EC.Timeline:ReserveDreamBreath(self.currentWaveIndex))
        EC.Timeline:HandleDreamBreathEmpowerStart(empower.castGUID, empower.castBarID, self.breathToken)
    end
    EC:Log("绿喷开始蓄力：W%d count=%d quota=%s generation=%d token=%s overQuota=%s",
        self.currentWaveIndex, self.breathCount, tostring(self.currentWaveLimit or "未确认"), self.armGeneration,
        self.breathToken and tostring(self.breathToken.tokenIndex) or "-", tostring(self.armedOverQuota))
    if self.armedOverQuota then self:ShowOverQuotaWarning() end
    self:NotifyChanged()
end

function CastTracker:HandleEmpowerStop(castGUID, spellID, complete, interruptedBy, castBarID)
    local received = ReadEmpowerIdentity(castGUID, spellID, castBarID)
    if received.spellID and not IsDreamBreath(received.spellID) then return end
    local empower = self.activeEmpower or self.prepullEmpower
    local match, key = MatchEmpowerIdentity(empower, received)
    local readableComplete, completeState = ReadIdentityField(complete, "boolean")
    if match == "NO_ACTIVE" then
        local duplicate = MatchEmpowerIdentity(self.lastClosedEmpower, received) == "MATCH"
        self:LogEmpower(duplicate and "EMPOWER_STOP_DUPLICATE" or "EMPOWER_STOP_WITHOUT_START",
            self.lastClosedEmpower, received, match, readableComplete)
        return
    end
    if match == "MISMATCH" then
        self:LogEmpower("EMPOWER_STOP_MISMATCH", empower, received, key, readableComplete)
        return -- Do not touch B's token, correction, confidence or armed state.
    end
    if match ~= "MATCH" then
        self:LogEmpower("EMPOWER_STOP_UNVERIFIABLE", empower, received, key, readableComplete)
        self:InvalidateEmpowerQuota("EMPOWER_STOP_UNVERIFIABLE")
        return -- An unknown STOP cannot even prove which cast should be cleared.
    end
    if completeState ~= "READABLE" then
        self:RejectEmpowerCommit(empower, "EMPOWER_COMPLETE_UNREADABLE")
        return
    end
    local commit, reason = self:FinalizeEmpowerStop(empower, readableComplete)
    if not commit then
        if reason ~= "EMPOWER_ALREADY_CLOSED" then self:RejectEmpowerCommit(empower, reason) end
        return
    end
    -- The matched/release diagnostics see the fully committed state as well.
    self:LogEmpower("EMPOWER_STOP_MATCHED", empower, received, key, readableComplete, completeState)
    self:NotifyEmpowerStop(commit)
end

-- Ball is a normal cast: reserve the exact reminder at START, then require
-- the same readable cast identity at SUCCEEDED. STOP is not proof of success.
function CastTracker:ClearBallCast(reason)
    local cast = self.ballCast
    self.ballCast = nil
    if cast then
        -- Session-local tombstones also reject a duplicate START after completion.
        self.closedBallCasts = self.closedBallCasts or {}
        self.closedBallCasts[#self.closedBallCasts+1] = cast
        if cast.event and cast.event.ballState == "CASTING" then
            EC.Timeline:SetBallSlotState(cast.event, "DUE", reason)
            if cast.snapshot == EC.Timeline.snapshot then EC.Timeline:RefreshBallSlots(EC.Timeline:GetElapsed()) end
        end
        self:LogEmpower("BALL_CLEAR", cast, nil, "CLEAR", nil, reason)
    end
    if EC.AlertUI and EC.AlertUI.ClearBallEmergency then EC.AlertUI:ClearBallEmergency() end
end

function CastTracker:IsBallCastPending(event)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return false end
    local cast = self.ballCast
    if not cast then return false end
    if not self.sessionActive or self.snapshot ~= cast.snapshot or Now() > cast.expiresAt then
        -- Lost-result watchdog, not postHold: never infers success. A retryable
        -- owner returns to DUE/LATE; an owner superseded by a newer slot is MISSED.
        self:ClearBallCast("会话结束或15秒无结果清理")
        return false
    end
    return cast.event == event
end

function CastTracker:StartBallCast(guid, spell, bar)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return end
    local id = ReadEmpowerIdentity(guid, spell, bar)
    if id.spellID ~= 373861 then return end
    if not id.castGUID and id.castBarID == nil then
        self:LogEmpower("BALL_START", nil, id, "UNVERIFIABLE", nil, "缺少可读起手身份，未确认")
        return
    end
    local timeline = EC.Timeline
    if not self.sessionActive or not timeline or not timeline.active or self.snapshot ~= timeline.snapshot then return end
    if self.closedBallSnapshot ~= self.snapshot then
        self.closedBallSnapshot = self.snapshot; self.closedBallCasts = {}
    end
    if self.ballCast and MatchEmpowerIdentity(self.ballCast, id) == "MATCH" then return end
    if self.ballCast and ((id.castGUID and self.ballCast.castGUID == id.castGUID)
        or (id.castBarID ~= nil and self.ballCast.castBarID == id.castBarID)) then
        return -- Conflicting fields for an already-owned identity cannot replace it.
    end
    for _, closed in ipairs(self.closedBallCasts or {}) do
        if (id.castGUID and closed.castGUID == id.castGUID)
            or MatchEmpowerIdentity(closed, id) == "MATCH" then return end
    end
    self:ClearBallCast("新的本人起手替代旧读条")
    local chosen, hasPlan = timeline:GetBallSlot(timeline:GetElapsed())
    if not hasPlan then return end -- Preserve absence of authority on a board with no personal ball slots.
    id.event, id.snapshot, id.startedAt = chosen, self.snapshot, Now()
    id.expiresAt = id.startedAt + 15
    id.disposition = chosen and "PLANNED" or
        (self.snapshot.absenceAllowed and self.snapshot.absenceAllowed.BALL and "ILLEGAL" or "UNASSIGNED_UNKNOWN")
    self.ballCast = id
    if chosen then
        timeline:SetBallSlotState(chosen, "CASTING")
        chosen.diagnosticVisibleLogged = true
        if EC.Voice then EC.Voice:CancelOwner(chosen) end
    elseif id.disposition == "ILLEGAL" then
        if EC.AlertUI and EC.AlertUI.ShowBallEmergency then EC.AlertUI:ShowBallEmergency() end
    end
    self:LogEmpower("BALL_START", id, id, id.disposition, nil,
        chosen and ("绑定 slot "..tostring(chosen.eventID)) or "未关联任何计划项")
    timeline:RenderNow()
end

function CastTracker:FinishBallCast(guid, spell, bar, succeeded)
    if EC.Features and not EC.Features:SkillEnabled("BALL") then return end
    local cast = self.ballCast
    if not cast or not self:IsBallCastPending(cast.event) then
        if succeeded then self:LogEmpower("BALL_SUCCEEDED", nil, ReadEmpowerIdentity(guid, spell, bar), "UNPAIRED", nil, "无有效手动起手") end
        return
    end
    local received = ReadEmpowerIdentity(guid, spell, bar)
    local match = MatchEmpowerIdentity(cast, received)
    self:LogEmpower(succeeded and "BALL_SUCCEEDED" or "BALL_FAILED", cast, received, match, succeeded)
    if match ~= "MATCH" then return end
    for _, closed in ipairs(self.closedBallCasts or {}) do
        if MatchEmpowerIdentity(closed, received) == "MATCH" then return end -- Ambiguous reused key, fail closed.
    end
    -- Only the exact START owner can finish. Never search for a slot at SUCCESS.
    if succeeded and cast.disposition == "PLANNED" and cast.event.ballState == "CASTING" then
        EC.Timeline:SetBallSlotState(cast.event, "DONE", "同一次时空畸体施法成功")
        if EC.Voice then EC.Voice:CancelOwner(cast.event) end
    end
    self:ClearBallCast(succeeded and "成功" or "中断或失败")
    if EC.Timeline and EC.Timeline.active then EC.Timeline:RenderNow() end
end

function CastTracker:HandleSucceeded(castGUID, spellID, castBarID)
    if spellID == 373861 then
        self:FinishBallCast(castGUID, spellID, castBarID, true)
        return
    end
    -- Dream Breath success is not the count point; empower stop is authoritative.
    if IsDreamBreath(spellID) then
        if self.sessionActive then
            EC:Log(
                "观察到绿喷 SUCCEEDED：不计数，guid=%s，bar=%s",
                tostring(castGUID),
                tostring(castBarID)
            )
        end
        return
    end

    if spellID == STASIS_ID then
        local castAt, accepted, treatedAsRelease = self:ObserveInitialStasis(castGUID, castBarID)

        if treatedAsRelease then
            if not (EC.Runtime and EC.Runtime.encounterActive) then
                self:ResetPrepullState("开怪前静滞释放回报")
            elseif self.sessionActive then
                self:DismissActiveReminder("RELEASE_STASIS", "静滞释放回报")
            end
            return
        end

        if not accepted then
            return
        end

        if not self.sessionActive and EC.Runtime and EC.Runtime.EnsureFreeTestSession then
            EC.Runtime:EnsureFreeTestSession()
        end

        if self.sessionActive then
            self:AdvanceActualWave(castGUID, castBarID, castAt, "实际施放静滞")
        end
        return
    end

    if STASIS_RELEASE_CAST_IDS[spellID] then
        self:ObserveStasisRelease(spellID)
        if self.sessionActive then
            self:DismissActiveReminder("RELEASE_STASIS", "实际释放静滞")
        end
        return
    end

    if not self.sessionActive then
        return
    end

    local skillKey = SUCCEEDED_SKILLS[spellID]
    if skillKey then
        self:DismissActiveReminder(skillKey, "实际技能施放")
        EC:Log("实际施放技能：%s", tostring(skillKey))
    end
end

function CastTracker:GetHUDData()
    return {
        quotaConfirmed = self:HasReliableQuota(),
        quotaReason = self.quotaConfirmed and not self:HasReliableQuota() and "PLANNED_WAVE_ENDED" or self.quotaReason,
        sessionActive = self.sessionActive,
        tracking = self.tracking,
        mode = self.sessionMode,
        waveIndex = self.currentWaveIndex,
        plannedWaveCount = self:GetPlannedWaveCount(),
        limit = self.currentWaveLimit,
        plannedLimit = self.currentWavePlannedLimit,
        debtApplied = self.currentWaveDebtApplied,
        count = self.breathCount,
        armed = self.breathArmed,
        armedOverQuota = self.armedOverQuota,
        borrowedThisWave = self.borrowedThisWave,
        borrowedTotal = self.borrowedTotal,
        safetyMode = self.safetyMode,
        waveMatchDelta = self.lastWaveMatchDelta,
        prepullStasisEligible = self.prepullStasisEligible,
        prepullDreamBreathCount = self.prepullDreamBreathCount or 0,
        prepullDreamBreathArmed = self.prepullDreamBreathArmed,
    }
end

function CastTracker:GetStatusText()
    if not self.sessionActive then
        return "当前没有记录"
    end

    if not self.tracking then
        return string.format(
            "等待静滞\n计划波次：%d",
            self:GetPlannedWaveCount()
        )
    end

    if not self:HasReliableQuota() then
        return "已喷 " .. self.breathCount .. " 次\n配额未确认 · 按 MRT 到点提醒"
    end
    local line2 = string.format(
        "第 %d 波　梦境吐息 %d / %s",
        self.currentWaveIndex,
        self.breathCount,
        self.currentWaveLimit ~= nil and tostring(self.currentWaveLimit) or "-"
    )

    local line3 = ""
    if self.currentWaveDebtApplied and self.currentWaveDebtApplied > 0 then
        line3 = string.format("\n本波已少 %d 次", self.currentWaveDebtApplied)
    end

    return line2 .. line3
end

function CastTracker:GetDiagnosticLines()
    return {
        "CastTracker：" .. tostring(self.sessionActive and "ACTIVE" or "IDLE"),
        "记录模式：" .. tostring(self.sessionMode),
        "实际静滞波次：" .. tostring(self.currentWaveIndex),
        "计划波次数：" .. tostring(self:GetPlannedWaveCount()),
        "MRT波次偏差：" .. tostring(self.lastWaveMatchDelta ~= nil and string.format("%+.2fs", self.lastWaveMatchDelta) or "-"),
        "MRT原配额：" .. tostring(self.currentWavePlannedLimit ~= nil and self.currentWavePlannedLimit or "-"),
        "当前有效配额：" .. tostring(self.currentWaveLimit ~= nil and self.currentWaveLimit or "-"),
        "前波预借扣除：" .. tostring(self.currentWaveDebtApplied or 0),
        "真实绿喷：" .. tostring(self.breathCount),
        "本波借用未来Token：" .. tostring(self.borrowedThisWave or 0),
        "整场借用Token：" .. tostring(self.borrowedTotal or 0),
        "蓄力 armed：" .. tostring(self.breathArmed),
        "蓄力超额：" .. tostring(self.armedOverQuota),
        "安全模式：" .. tostring(self.safetyMode),
        "预开怪静滞候选：" .. tostring(self.prepullStasisEligible),
        "预开怪已缓存绿喷：" .. tostring(self.prepullDreamBreathCount or 0),
        "预开怪绿喷蓄力中：" .. tostring(self.prepullDreamBreathArmed),
        "最近停止：" .. tostring(self.lastStopReason or "-"),
    }
end

function CastTracker:Initialize()
    if self.initialized then
        return
    end

    self.initialized = true

    local frame = CreateFrame("Frame")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
    frame:RegisterUnitEvent("UNIT_AURA", "player")
    frame:RegisterEvent("PLAYER_DEAD")

    local function OnCastEvent(_, event, ...)
        if not EC.state.dbReady or not EC.db.enabled or (EC.Runtime and not EC.Runtime:CanRun()) then return end
        if event == "PLAYER_DEAD" then
            CastTracker:ClearBallCast("死亡")
            CastTracker:LogEmpower("EMPOWER_DEATH_CLEANUP", CastTracker.activeEmpower or CastTracker.prepullEmpower, nil, "ABANDON")
            CastTracker:AbandonEmpower("player_dead")
            if not (EC.Runtime and EC.Runtime.encounterActive) then CastTracker:ResetPrepullState("战前死亡") end
            CastTracker:NotifyChanged()
            return
        end
        if event == "UNIT_AURA" then
            if EC.Runtime and EC.Runtime.encounterActive then return end
            CastTracker:CheckPrepullAura()
            return
        end
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            local unit, guid, spell, bar = ...
            if EC:IsSecret(unit) or unit ~= "player" then return end
            if event == "UNIT_SPELLCAST_START" then CastTracker:StartBallCast(guid, spell, bar)
            else CastTracker:FinishBallCast(guid, spell, bar, false) end
            return
        end
        if event == "UNIT_SPELLCAST_EMPOWER_START" then
            local unit, castGUID, spellID, castBarID = ...
            -- RegisterUnitEvent already restricts these events to player. Never
            -- compare secret payloads; handlers validate identity before using it.
            if not EC:IsSecret(unit) and unit ~= "player" then return end
            CastTracker:HandleEmpowerStart(castGUID, spellID, castBarID)
            return
        end

        if event == "UNIT_SPELLCAST_EMPOWER_STOP" then
            local unit, castGUID, spellID, complete, interruptedBy, castBarID = ...
            if not EC:IsSecret(unit) and unit ~= "player" then return end
            CastTracker:HandleEmpowerStop(castGUID, spellID, complete, interruptedBy, castBarID)
            return
        end

        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, castGUID, spellID, castBarID = ...
            if EC:IsSecret(unit) or EC:IsSecret(spellID) then
                if EC.PlanGuard then EC.PlanGuard:Warn("RESTRICTED_EVENT", "当前施法回报不可读，配额纠错暂停；请在本场结束后用 /evc log 提交反馈。") end
                if CastTracker.sessionActive then CastTracker:SetUnconfirmed("RESTRICTED_EVENT", false) end
                return
            end
            if EC:IsSecret(castGUID) then castGUID = nil end
            if EC:IsSecret(castBarID) then castBarID = nil end
            if unit == "player" then
                CastTracker:HandleSucceeded(castGUID, spellID, castBarID)
            end
        end
    end
    frame:SetScript("OnEvent", function(...)
        if EC.Diagnostics and EC.Diagnostics.Run then EC.Diagnostics:Run("施法记录", OnCastEvent, ...)
        else OnCastEvent(...) end
    end)

    self.eventFrame = frame
    self:NotifyChanged()
end
