local addonName, EC = ...

local Diagnostics = {}
EC.Diagnostics = Diagnostics

local MAX_SESSIONS = 20
local MAX_SESSION_ENTRIES = 2400
local KEEP_HEAD_ENTRIES = 400
local MAX_GLOBAL_ENTRIES = 600
local MAX_NOTE_CHARS = 65535

Diagnostics.initialized = false
Diagnostics.db = nil
Diagnostics.active = nil
Diagnostics.bootTime = nil

local function Now()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return GetTime()
end

local function Clock()
    return date and date("%Y-%m-%d %H:%M:%S") or "unknown"
end

local function CopyArray(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        table.insert(out, value)
    end
    return out
end

local function TrimOldest(list, maxCount)
    while #list > maxCount do
        table.remove(list, 1)
    end
end

local function SafeText(value)
    return EC:SafeText(value)
end

local function CopySafe(value, depth)
    if EC:IsSecret(value) then return "<restricted>" end
    local kind = type(value)
    if kind == "string" then return value:sub(1, 65535) end
    if kind ~= "table" then
        if kind == "number" or kind == "boolean" or kind == "nil" then return value end
        return "<" .. kind .. ">"
    end
    depth = depth or 0
    if depth >= 7 then return "<depth-limit>" end
    local out, count = {}, 0
    for key, item in pairs(value) do
        if not EC:IsSecret(key) and (type(key) == "number" or type(key) == "string") then
            out[key] = CopySafe(item, depth + 1)
        end
        count = count + 1
        if count >= 2500 then break end
    end
    return out
end

local function GetBuildSnapshot()
    local version, build, buildDate, tocVersion = GetBuildInfo()
    return {
        version = version,
        build = build,
        buildDate = buildDate,
        tocVersion = tocVersion,
    }
end

local function GetZoneSnapshot()
    local name, instanceType, difficultyID, difficultyName, maxPlayers,
        dynamicDifficulty, isDynamic, instanceID = GetInstanceInfo()

    return {
        name = name,
        instanceType = instanceType,
        difficultyID = difficultyID,
        difficultyName = difficultyName,
        maxPlayers = maxPlayers,
        dynamicDifficulty = dynamicDifficulty,
        isDynamic = isDynamic,
        instanceID = instanceID,
    }
end

function Diagnostics:Initialize()
    if self.initialized then
        return
    end

    if type(EvokerCueLogDB) ~= "table" then
        EvokerCueLogDB = {}
    end

    EvokerCueLogDB.formatVersion = 2
    EvokerCueLogDB.addonVersion = EC.VERSION
    EvokerCueLogDB.sessions = type(EvokerCueLogDB.sessions) == "table" and EvokerCueLogDB.sessions or {}
    EvokerCueLogDB.global = type(EvokerCueLogDB.global) == "table" and EvokerCueLogDB.global or {}

    self.db = EvokerCueLogDB
    self.initialized = true
    self.bootTime = Now()
    self.bootID = Clock() .. ":" .. tostring(self.bootTime)
    self.errorsSeen = {}
    for _, session in ipairs(self.db.sessions) do
        if not session.endedAt then
            session.incomplete = true
            session.endReason = session.endReason or "上次记录未收到首领结束事件"
            session.perfStart = nil
        end
    end
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function()
        if self.active then
            self.active.incomplete = true
            self:CaptureFinalState("logout_or_reload")
            self:EndSession("退出或重载；不代表首领已结束")
        end
    end)
    self.logoutFrame = frame
    self.checkpointTicker = C_Timer.NewTicker(5, function() self:Checkpoint() end)

    TrimOldest(self.db.sessions, MAX_SESSIONS)
    TrimOldest(self.db.global, MAX_GLOBAL_ENTRIES)

    self:Event("BOOT", string.format(
        "EvokerCue=%s game=%s build=%s toc=%s",
        SafeText(EC.VERSION),
        SafeText((GetBuildInfo())),
        SafeText(select(2, GetBuildInfo())),
        SafeText(select(4, GetBuildInfo()))
    ), true)
end

function Diagnostics:GetRelativeTime()
    if self.active and self.active.perfStart then
        return math.max(0, Now() - self.active.perfStart)
    end
    if self.bootTime then
        return math.max(0, Now() - self.bootTime)
    end
    return 0
end

function Diagnostics:AppendEntry(target, kind, message, maxCount)
    if type(target) ~= "table" then
        return
    end

    table.insert(target, {
        t = math.floor(self:GetRelativeTime() * 1000 + 0.5) / 1000,
        clock = Clock(),
        kind = SafeText(kind),
        message = SafeText(message):sub(1, 4096),
        mono = Now(),
        bootID = self.bootID,
        encounterElapsed = self.active and self.active.timelineStart
            and math.max(0, Now() - self.active.timelineStart) or nil,
    })
    if self.active and target == self.active.entries and #target > maxCount then
        table.remove(target, KEEP_HEAD_ENTRIES + 1)
        self.active.droppedEntries = (self.active.droppedEntries or 0) + 1
    else TrimOldest(target, maxCount) end
end

function Diagnostics:Event(kind, message, forceGlobal)
    if not self.initialized or not self:IsEnabled() then return end

    if self.active and not forceGlobal then
        self:AppendEntry(self.active.entries, kind, message, MAX_SESSION_ENTRIES)
    else
        self:AppendEntry(self.db.global, kind, message, MAX_GLOBAL_ENTRIES)
    end
end

function Diagnostics:RecordLog(text)
    self:Event("LOG", text)
end

function Diagnostics:RuntimeEvent(event, ...)
    local args = { ... }
    local rendered = {}
    for index = 1, math.min(8, #args) do
        table.insert(rendered, SafeText(args[index]))
    end

    self:Event(
        "WOW_EVENT",
        tostring(event) .. (#rendered > 0 and (" | " .. table.concat(rendered, " | ")) or "")
    )
end

function Diagnostics:BeginSession(source, metadata)
    if not self:IsEnabled() then return end
    if source ~= "BOSS" and source ~= "BOSS_RELOAD" then
        self:Event("NON_BOSS_SESSION", source or "UNKNOWN", true)
        return
    end
    if not self.initialized then
        self:Initialize()
    end

    if self.active then
        self:EndSession("被新会话替换")
    end

    local identity = EC:GetPlayerIdentity()
    local candidates = {}
    for _, candidate in ipairs(identity and identity.candidates or {}) do
        table.insert(candidates, {
            value = candidate.value,
            source = candidate.source,
        })
    end

    local game = identity and identity.game or {}
    local runtime = EC.db and EC.db.runtime or {}
    local reminder = EC.db and EC.db.reminder or {}
    local voice = EC.db and EC.db.voice or {}

    local session = {
        id = string.format("%s-%d", date and date("%Y%m%d-%H%M%S") or "session", math.floor(Now() * 1000) % 1000000),
        addonVersion = EC.VERSION,
        startedAt = Clock(),
        endedAt = nil,
        duration = nil,
        endReason = nil,
        source = source or "UNKNOWN",
        perfStart = Now(),
        build = GetBuildSnapshot(),
        zone = GetZoneSnapshot(),
        metadata = metadata or {},
        settings = {
            enabled = EC.db and EC.db.enabled,
            combatOnly = runtime.combatOnly,
            onlyVenomousAbyss = runtime.onlyVenomousAbyss,
            reminderEnabled = reminder.enabled,
            leadTime = reminder.leadTime,
            postHold = reminder.postHold,
            earlyWarningThreshold = reminder.earlyWarningThreshold,
            reminderStrata = reminder.strata,
            emergencyStrata = reminder.emergencyStrata,
            voiceEnabled = voice.enabled,
            voiceNormalEnabled = voice.normalEnabled,
            voiceCorrectionEnabled = voice.correctionEnabled,
            voiceChannel = voice.channel,
        },
        identity = {
            mode = identity and identity.mode,
            shortName = game.shortName,
            fullName = game.fullName,
            realmName = game.realmName,
            className = game.className,
            classFile = game.classFile,
            role = game.role,
            candidates = candidates,
        },
        plan = nil,
        finalState = nil,
        entries = {},
        casts = {},
        prelude = {},
        droppedEntries = 0,
        partial = metadata and metadata.partial or false,
    }
    local bossStart = EC.Runtime and EC.Runtime.encounterStartTime
    if source == "BOSS" and type(bossStart) == "number" then
        session.timelineStart = bossStart
        session.recordingOffset = math.max(0, session.perfStart - bossStart)
    end
    session.clockKnown = session.timelineStart ~= nil
    if session.partial then session.incomplete = true end
    for i = math.max(1, #self.db.global - 159), #self.db.global do
        local entry = self.db.global[i]
        if entry and entry.mono and entry.bootID == self.bootID then
            local copied = CopySafe(entry)
            copied.relativeToStart = entry.mono - session.perfStart
            session.prelude[#session.prelude + 1] = copied
        end
    end
    session.prepull = EC.CastTracker and EC.CastTracker:GetPrepullSnapshot() or nil

    table.insert(self.db.sessions, session)
    TrimOldest(self.db.sessions, MAX_SESSIONS)
    self.active = session

    self:Event("SESSION_BEGIN", string.format(
        "source=%s zone=%s instanceID=%s encounterID=%s difficultyID=%s",
        SafeText(session.source),
        SafeText(session.zone and session.zone.name),
        SafeText(session.zone and session.zone.instanceID),
        SafeText(metadata and metadata.encounterID),
        SafeText(metadata and metadata.difficultyID)
    ))
end

function Diagnostics:CapturePlan(noteText, info, identity, result, reason)
    if not self.active then
        return
    end

    noteText = type(noteText) == "string" and noteText or ""
    local storedNote = noteText
    local noteTruncated = false
    if #storedNote > MAX_NOTE_CHARS then
        storedNote = storedNote:sub(1, MAX_NOTE_CHARS)
        noteTruncated = true
    end

    local candidates = {}
    for _, candidate in ipairs(identity and identity.candidates or {}) do
        table.insert(candidates, {
            value = candidate.value,
            source = candidate.source,
        })
    end

    local events = {}
    for _, event in ipairs(result and result.events or {}) do
        table.insert(events, {
            time = event.time,
            lineNumber = event.lineNumber,
            sequence = event.sequence,
            skillKey = event.skillKey,
            skillName = event.skillName,
            spellID = event.spellID,
            waveIndex = event.waveIndex,
            breathIndex = event.breathIndex,
            breathLimit = event.breathLimit,
            quotaReliable = event.quotaReliable,
            matchedPlayerName = event.matchedPlayerName,
            matchedPlayerSource = event.matchedPlayerSource,
            rawLine = event.rawLine,
            cleanContent = event.cleanContent,
            sourceOrigin = event.sourceOrigin,
        })
    end

    local waves = {}
    for _, wave in ipairs(result and result.waves or {}) do
        table.insert(waves, {
            index = wave.index,
            stasisTime = wave.stasisTime,
            nextStasisTime = wave.nextStasisTime,
            breathLimit = wave.breathLimit,
            mappingReliable = wave.mappingReliable,
            quotaReliable = wave.quotaReliable,
            invalidReason = wave.invalidReason,
        })
    end

    local warnings = {}
    for _, warning in ipairs(result and result.warnings or {}) do
        table.insert(warnings, warning)
    end

    local counts = {}
    for key, value in pairs(result and result.counts or {}) do
        counts[key] = value
    end

    local stats = {}
    for key, value in pairs(result and result.stats or {}) do
        stats[key] = value
    end

    self.active.plan = {
        reason = reason,
        capturedAt = Clock(),
        mrtAvailable = info and info.available == true,
        mrtNamespace = info and info.namespace,
        planSource = info and info.source,
        sourceStatus = info and info.status,
        sourceSelection = info and info.selection,
        noteLength = #noteText,
        noteHash = EC.MRTReader and EC.MRTReader:HashText(noteText) or nil,
        noteTruncated = noteTruncated,
        noteText = storedNote,
        identityMode = identity and identity.mode,
        candidates = candidates,
        parserOK = result and result.ok or false,
        parserStatus = result and result.status,
        parserStatusText = result and result.statusText,
        matchedPlayerName = result and result.matchedPlayerName,
        matchedPlayerSource = result and result.matchedPlayerSource,
        waveQuotaText = result and result.waveQuotaText,
        counts = counts,
        stats = stats,
        warnings = warnings,
        planIssues = CopySafe(result and result.planIssues),
        integrity = CopySafe(result and result.integrity),
        negativeCorrectionAllowed = result and result.negativeCorrectionAllowed == true,
        absenceAllowed = CopySafe(result and result.absenceAllowed),
        openingReleaseMissing = result and result.openingReleaseMissing,
        orphanBreathCount = result and result.orphanBreathCount,
        waves = waves,
        events = events,
    }

    self:Event("PLAN_CAPTURE", string.format(
        "mrt=%s ns=%s chars=%d parser=%s status=%s match=%s events=%d waves=%s",
        tostring(info and info.available == true),
        SafeText(info and info.namespace),
        #noteText,
        tostring(result and result.ok or false),
        SafeText(result and result.status),
        SafeText(result and result.matchedPlayerName),
        #(result and result.events or {}),
        SafeText(result and result.waveQuotaText)
    ))
end

function Diagnostics:CaptureFinalState(label)
    if not self.active then
        return
    end

    local timeline = EC.Timeline
    local cast = EC.CastTracker

    local tokenLedger = nil
    if timeline and timeline.GetTokenLedgerStatus then
        tokenLedger = timeline:GetTokenLedgerStatus()
    end

    local castHUD = nil
    if cast and cast.GetHUDData then
        castHUD = cast:GetHUDData()
    end

    local outcomes = {}
    for _, event in ipairs(timeline and timeline.snapshot and timeline.snapshot.events or {}) do
        if #outcomes >= 2000 then break end
        outcomes[#outcomes + 1] = { id = event.eventID, token = event.tokenIndex,
            skill = event.skillKey, wave = event.waveIndex, time = event.time,
            consumed = event.consumed, expired = event.expired, dismissed = event.dismissed,
            reminderClosed = event.reminderClosed, consumedAt = event.consumedAt,
            consumedByWave = event.consumedByWave, consumptionReason = event.consumptionReason,
            closeReason = event.closeReason, quotaReliable = event.quotaReliable }
    end
    self.active.reminderOutcomes = outcomes
    self.active.finalState = {
        label = label,
        capturedAt = Clock(),
        timelineActive = timeline and timeline.active or false,
        timelineSource = timeline and timeline.source or nil,
        timelineElapsed = timeline and timeline.GetElapsed and timeline:GetElapsed() or nil,
        timelineVisibleCount = timeline and timeline.visibleCount or nil,
        tokenLedger = tokenLedger,
        castHUD = castHUD,
    }
end

function Diagnostics:EndSession(reason)
    if not self.active then
        return
    end

    if not self.active.finalState then
        self:CaptureFinalState("before_end")
    end
    self:Event("SESSION_END", SafeText(reason))

    self.active.endedAt = Clock()
    self.active.duration = math.floor((Now() - (self.active.perfStart or Now())) * 1000 + 0.5) / 1000
    self.active.endReason = reason or "未知"
    self.active.perfStart = nil

    self.active = nil
    TrimOldest(self.db.sessions, MAX_SESSIONS)
end

function Diagnostics:GetSessionCount()
    if not self.db or type(self.db.sessions) ~= "table" then
        return 0
    end
    return #self.db.sessions
end

function Diagnostics:IsEnabled()
    return EC.db and EC.db.diagnostics and EC.db.diagnostics.enabled ~= false
end

function Diagnostics:Checkpoint()
    if not self.active or not self:IsEnabled() then return end
    self.active.lastSeenAt = Clock()
    self.active.lastElapsed = self:GetRelativeTime()
    self.active.lastEncounterElapsed = self.active.timelineStart and math.max(0, Now() - self.active.timelineStart) or nil
    self.active.lastState = CopySafe(EC.CastTracker and EC.CastTracker:GetHUDData())
end

function Diagnostics:RecordCast(fields, targetSession)
    if not self.initialized or not self:IsEnabled() then return end
    local record = CopySafe(fields)
    local session = targetSession or self.active
    record.mono, record.bootID = Now(), self.bootID
    record.t = self:GetRelativeTime()
    record.encounterElapsed = session and session.timelineStart and math.max(0, record.mono - session.timelineStart) or nil
    if not session then
        -- Prepull START/STOP must retain structured identities too. Reuse the
        -- bounded global/prelude log, without another SavedVariables store.
        self:AppendEntry(self.db.global, "CAST", record.event, MAX_GLOBAL_ENTRIES)
        self.db.global[#self.db.global].cast = record
        return
    end
    if not session.perfStart and record.encounterElapsed then
        record.t = math.max(0, record.encounterElapsed - (session.recordingOffset or 0))
    end
    session.casts = session.casts or {}
    table.insert(session.casts, record)
    if #session.casts > 600 then
        table.remove(session.casts, 101)
        session.droppedCasts = (session.droppedCasts or 0) + 1
    end
end

local function ObservedField(value, kind)
    if EC:IsSecret(value) then return nil, "RESTRICTED" end
    if value == nil then return nil, "MISSING" end
    if type(value) ~= kind then return nil, "INVALID" end
    if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
        return nil, "INVALID"
    end
    return value, "READABLE"
end

local function EmpowerState(empower)
    if not empower then return nil end
    return { castGUID = empower.castGUID, castBarID = empower.castBarID, spellID = empower.spellID,
        generation = empower.generation, startedAt = empower.startedAt, closed = empower.closed == true }
end

local function ClientState(observedToken)
    local cast, timeline = EC.CastTracker, EC.Timeline
    if not cast then return {} end
    local active = cast.activeEmpower or cast.prepullEmpower
    local token = observedToken or (active and active.token)
    local reliable = cast:HasReliableQuota()
    local state = { sessionActive = cast.sessionActive, timelineActive = timeline and timeline.active,
        mode = cast.sessionMode, wave = cast.currentWaveIndex, count = cast.breathCount,
        allowed = reliable and cast.currentWaveLimit or nil, quotaReliable = reliable,
        quotaReason = cast.quotaReason,
        planWaveReason = cast.snapshot and cast.snapshot.waves
            and cast.snapshot.waves[cast.currentWaveIndex or 0]
            and cast.snapshot.waves[cast.currentWaveIndex or 0].invalidReason,
        debtApplied = cast.currentWaveDebtApplied,
        borrowedThisWave = cast.borrowedThisWave, borrowedTotal = cast.borrowedTotal,
        activePresent = cast.activeEmpower ~= nil, prepullPresent = cast.prepullEmpower ~= nil,
        active = EmpowerState(cast.activeEmpower), prepull = EmpowerState(cast.prepullEmpower),
        lastClosed = EmpowerState(cast.lastClosedEmpower), prepullCount = cast.prepullDreamBreathCount,
        tokenPresent = type(token) == "table" }
    if state.allowed ~= nil then state.remaining = math.max(0, state.allowed - state.count) end
    if type(token) == "table" then
        state.token = { index = token.tokenIndex, wave = token.waveIndex,
            reserved = token.reserved == true, consumed = token.consumed == true, expired = token.expired == true,
            ownerGeneration = token.empowerGeneration, consumedByWave = token.consumedByWave }
    end
    return CopySafe(state)
end

-- Observations only: no matching, reservation, counting or recovery decisions.
-- BEFORE is copied locally; persistence/callbacks happen after the handler.
local function ArgumentShape(value)
    -- Never compare, stringify, coerce or persist a secret/raw argument.
    if EC:IsSecret(value) then return { state = "RESTRICTED" } end
    if value == nil then return { state = "MISSING", kind = "nil" } end
    return { state = "READABLE", kind = type(value) }
end

function Diagnostics:PrepareClientObservation(_, event, ...)
    local unit, castGUID, spellID, arg4, arg5, arg6 = ...
    if not self.initialized or not self:IsEnabled() then return nil end
    local castEvent = event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_EMPOWER_STOP"
        or event == "UNIT_SPELLCAST_SUCCEEDED"
    if not castEvent and event ~= "PLAYER_DEAD" and event ~= "ENCOUNTER_START" and event ~= "ENCOUNTER_END" then return nil end
    local input = {}
    if castEvent then
        input.unit, input.unitState = ObservedField(unit, "string")
        if input.unit and input.unit ~= "player" then return nil end
        input.castGUID, input.guidState = ObservedField(castGUID, "string")
        input.spellID, input.spellState = ObservedField(spellID, "number")
        local id = input.spellID
        if id and id ~= 355936 and id ~= 382614 and id ~= 370537 and id ~= 370562 and id ~= 370564 then return nil end
        if event == "UNIT_SPELLCAST_EMPOWER_STOP" then
            input.castBarID, input.barState = EC:ReadCastBarID(arg6)
            input.complete, input.completeState = ObservedField(arg4, "boolean")
            input.interruptedBy, input.interruptedByState = ObservedField(arg5, "string")
        else input.castBarID, input.barState = EC:ReadCastBarID(arg4) end
        -- Fixed positions retain holes and trailing nils. No new raw values.
        input.shapeSchema = "EVC_CAST_SHAPE_1"
        input.argumentCount = select("#", ...)
        input.argumentShapes = {}
        for index = 1, 8 do
            input.argumentShapes[index] = ArgumentShape(select(index, ...))
        end
    end
    local cast = EC.CastTracker
    local empower = cast and (cast.activeEmpower or cast.prepullEmpower)
    self.clientEventSequence = (self.clientEventSequence or 0) + 1
    return { record = { event = "CLIENT_EVENT", clientEvent = event, input = input,
        sequence = self.clientEventSequence, receivedAt = Now(), before = ClientState() },
        token = empower and empower.token, session = self.active }
end

function Diagnostics:FinishClientObservation(observation, handlerOK)
    local record = observation.record
    record.handlerOK = handlerOK
    record.after = ClientState(observation.token)
    local before, after = record.before.token, record.after.token
    record.reservationReleased = before ~= nil and before.reserved and after ~= nil and not after.reserved
    -- EndSession has already closed self.active. Attach the AFTER observation
    -- to that same completed Boss record without replacing its pre-stop totals.
    self:RecordCast(record, record.clientEvent == "ENCOUNTER_END" and observation.session or nil)
end

function Diagnostics:Run(scope, func, ...)
    local observed, observation = pcall(self.PrepareClientObservation, self, ...)
    local ok, result = pcall(func, ...)
    if observed and observation then pcall(self.FinishClientObservation, self, observation, ok) end
    if ok then return result end
    local text = SafeText(result):sub(1, 2000)
    self.errorsSeen = self.errorsSeen or {}
    local signature = scope .. ":" .. text
    if not self.errorsSeen[signature] then
        self.errorsSeen[signature] = true
        self:Event("LUA_ERROR", signature)
        if self.active then self.active.hasLuaError = true end
        print("|cffffc857[奶龙打地鼠]|r " .. scope .. "出现异常，已暂停不可靠的纠错。请在本场结束后 /reload，再用 /evc log 查看反馈方法。")
    end
    if EC.CastTracker then
        EC.CastTracker.quotaConfirmed = false
        EC.CastTracker.currentWaveLimit = nil
        EC.CastTracker.quotaReason = "LUA_ERROR"
    end
    if EC.CastTracker then pcall(EC.CastTracker.ClearArm, EC.CastTracker, "LUA_ERROR") end
    if EC.Timeline and EC.Timeline.active then
        pcall(EC.Timeline.InvalidateRecord, EC.Timeline, "LUA_ERROR",
            EC.CastTracker and EC.CastTracker.currentWaveIndex or 0)
    end
    if EC.Voice then EC.Voice:Stop(true) end
    if EC.AlertUI then
        pcall(EC.AlertUI.ClearEmergency, EC.AlertUI)
        if EC.AlertUI.frame then EC.AlertUI.frame:Hide() end
    end
    if EC.TrackerHUD then pcall(EC.TrackerHUD.Update, EC.TrackerHUD) end
    return nil
end

function Diagnostics:SetEnabled(enabled)
    if not EC.db or not EC.db.diagnostics then return end
    enabled = enabled and true or false
    if enabled == (self:IsEnabled() and true or false) then return end
    if not enabled and self.active then
        self.active.incomplete = true
        self:CaptureFinalState("logging_disabled")
        self:EndSession("玩家关闭反馈日志；不代表首领已结束")
    end
    EC.db.diagnostics.enabled = enabled
    if enabled and EC.Runtime and EC.Runtime.encounterActive and EC.Runtime:CanRun() and not self.active then
        self:BeginSession("BOSS", { encounterID = EC.Runtime.encounterID,
            difficultyID = EC.Runtime.difficultyID, partial = true, loggingResumed = true })
        if not self.active then return end
        -- Use the frozen plan already in use, never re-read or re-parse the MRT
        -- editor here: toggling diagnostics must not change the live timeline.
        if EC.Runtime.sessionSource == "BOSS" and EC.state.result then
            self:CapturePlan(EC.state.noteText, {
                available = EC.state.mrtAvailable, namespace = EC.state.mrtNamespace,
            }, EC.state.identity, EC.state.result, "战斗中开启反馈日志：沿用本场开怪战术板")
        else
            self.active.planUnavailable = true
        end
        self.active.resumeState = CopySafe(EC.CastTracker and EC.CastTracker:GetHUDData())
        self:Event("LOGGING_RESUMED", "此前关闭期间的施法无法补录；战斗起点和当前记录不重置")
        self:Checkpoint()
    end
end

function Diagnostics:PrintUploadHelp()
    if self.active then
        self:Event("PLAYER_FEEDBACK_MARK", "玩家在本场输入 /evc log")
        self:Checkpoint()
    end
    local prefix = "|cff52d6a0[奶龙打地鼠]|r "
    print(prefix .. EC.VERSION .. " · " .. (self:IsEnabled() and "反馈日志已开启" or "反馈日志已关闭") .. "，现存 " .. self:GetSessionCount() .. " 场，最多保留最近 20 场首领记录。")
    print(prefix .. "请等本场结束后 |cffffffff/reload|r 或正常退出游戏，再把以下文件发到 QQ 群 |cffffffff251935247|r：")
    print("|cffffffffWorld of Warcraft\\_retail_\\WTF\\Account\\<账号>\\SavedVariables\\EvokerCue.lua|r")
    print(prefix .. "请附上首领、难度、大概时间和问题现象。正常使用也欢迎反馈；日志含角色名与 MRT 原文，仅本地保存，不会自动上传。")
end
