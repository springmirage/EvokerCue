local addonName, EC = ...

local Voice = {}
EC.Voice = Voice

local SOUND_ROOT = "Interface\\AddOns\\" .. addonName .. "\\Sounds\\"

Voice.SKILL_FILES = {
    DREAM_BREATH = { file = "dream_breath.ogg", duration = 0.532, label = "绿喷" },
    STASIS = { file = "stasis.ogg", duration = 0.566, label = "静滞" },
    RELEASE_STASIS = { file = "release_stasis.ogg", duration = 0.889, label = "放静滞" },
    REWIND = { file = "rewind.ogg", duration = 0.696, label = "回溯" },
    ZEPHYR = { file = "zephyr.ogg", duration = 0.596, label = "微风" },
    SPATIAL_PARADOX = { file = "spatial_paradox.ogg", duration = 0.863, label = "悖论" },
    TIME_SPIRAL = { file = "time_spiral.ogg", duration = 1.031, label = "时间螺旋" },
}

Voice.SPECIAL_FILES = {
    EARLY = { file = "breath_early.ogg", duration = 0.617, label = "先别喷" },
    LATE = { file = "breath_late.ogg", duration = 0.741, label = "绿喷晚啦" },
    CANCEL = { file = "breath_cancel.ogg", duration = 0.794, label = "取消绿喷" },
}

Voice.initialized = false
Voice.queue = {}
Voice.playing = false
Voice.currentHandle = nil
Voice.generation = 0
Voice.gap = 0.08

local function GetChannel()
    local db = EC.db and EC.db.voice
    local channel = db and db.channel or "Master"
    if channel ~= "Master" and channel ~= "SFX" and channel ~= "Dialog" then
        channel = "Master"
    end
    return channel
end

local function CanPlay(kind, force)
    if not EC.state.dbReady or not EC.db.enabled then return false end
    -- Explicit sound-page previews work outside the allowed raid zones.
    -- The global addon switch remains authoritative for every playback.
    if force then return true end
    if EC.Runtime and not EC.Runtime:CanRun() then return false end
    if not EC.db.voice or not EC.db.voice.enabled then return false end
    if kind == "NORMAL" then return EC.db.voice.normalEnabled ~= false and EC.db.reminder.enabled end
    if kind == "CORRECTION" then return EC.db.voice.correctionEnabled ~= false end
    return true
end

function Voice:GetBackend()
    return EC.db and EC.db.voice and EC.db.voice.backend == "OGG" and "OGG" or "TTS"
end
function Voice:SetBackend(backend)
    if backend ~= "TTS" and backend ~= "OGG" then return false end
    if not EC.state.dbReady or not EC.db.voice then return false end
    self:Stop(true)
    EC.db.voice.backend = backend
    return true
end
function Voice:CheckBackend(force)
    if self:GetBackend() == "OGG" then return PlaySoundFile ~= nil end
    if EC.TTS then return EC.TTS:Ready(force) end
    if force or not self.missingTTSWarned then
        self.missingTTSWarned = true
        print("|cffffc857[奶龙打地鼠]|r 内置TTS暂不可用，请在声音设置切换“内置语音包”。")
    end
    return false
end

function Voice:Initialize()
    if self.initialized then return end
    self.initialized = true
    self.queue, self.playing, self.currentHandle, self.currentItem = {}, false, nil, nil
    self.generation = 0
end

function Voice:Stop(clearQueue)
    self.generation = self.generation + 1
    if self.currentHandle and StopSound then pcall(StopSound, self.currentHandle, 0) end
    self.currentHandle, self.currentItem, self.playing = nil, nil, false
    if clearQueue ~= false then wipe(self.queue) end
end

function Voice:IsValid(item)
    if not CanPlay(item.kind, item.force) then return false end
    if item.backend and item.backend ~= self:GetBackend() then return false end
    if item.force then return true end
    if item.special == "CANCEL" then
        local cast = EC.CastTracker
        return cast and cast.sessionActive and cast.breathArmed and cast.armedOverQuota
            and cast.armGeneration == item.castGeneration
            and cast.sessionStartTime == item.castSessionStart
            and cast.currentWaveIndex == item.castWave and cast:HasReliableQuota() or false
    end
    local event = item.owner
    if not event then return true end
    if not EC.Timeline or not EC.Timeline.active or EC.Timeline.snapshot ~= item.snapshot then return false end
    if event.consumed or event.expired or event.dismissed or event.reminderClosed then return false end
    local elapsed = EC.Timeline:GetElapsed()
    if item.special == "EARLY" then
        return EC.db.reminder.enabled and event.earlyWarningActive and EC.Timeline:CanCorrectEvent(event, elapsed)
    elseif item.special == "LATE" then
        return EC.db.reminder.enabled and EC.Timeline:CanTrackKnownSlot(event, elapsed)
            and elapsed > event.time + (EC.db.reminder.postHold or 0.9)
    end
    return elapsed <= event.time + (EC.db.reminder.postHold or 0.9)
end

function Voice:Prune()
    for i = #self.queue, 1, -1 do
        if not self:IsValid(self.queue[i]) then table.remove(self.queue, i) end
    end
    if self.currentItem and not self:IsValid(self.currentItem) then self:Stop(false) end
    if not self.playing then self:Pump() end
end

function Voice:CancelOwner(owner, kind)
    for i = #self.queue, 1, -1 do
        local item = self.queue[i]
        if item.owner == owner and (not kind or item.kind == kind) then table.remove(self.queue, i) end
    end
    local item = self.currentItem
    if item and item.owner == owner and (not kind or item.kind == kind) then
        self:Stop(false)
        self:Pump()
    end
end

-- Cancel only the live warning for an empower attempt. Explicit preview audio
-- and unrelated, still-valid MRT skill cues retain their own queue lifetimes.
function Voice:CancelCastWarning()
    for i = #self.queue, 1, -1 do
        local item = self.queue[i]
        if item.special == "CANCEL" and not item.force then table.remove(self.queue, i) end
    end
    if self.currentItem and self.currentItem.special == "CANCEL" and not self.currentItem.force then
        self:Stop(false)
        self:Pump()
    end
end

function Voice:Pump()
    if self.playing then return end
    local item
    while #self.queue > 0 do
        local nextItem = table.remove(self.queue, 1)
        if self:IsValid(nextItem) then item = nextItem; break end
    end
    if not item then return end
    local submitted, handle, duration = false, nil, item.duration
    if item.backend == "TTS" then
        if EC.TTS then submitted, duration = EC.TTS:Speak(item.label, item.force) end
        if submitted then EC:Log("已提交TTS：%s（未确认实际出声）", item.label) end
    elseif PlaySoundFile then
        local ok, willPlay, soundHandle = pcall(PlaySoundFile, SOUND_ROOT .. item.file, GetChannel())
        submitted = ok and not EC:IsSecret(willPlay) and willPlay or false
        handle = not EC:IsSecret(soundHandle) and soundHandle or nil
        if submitted then EC:Log("播放语音：%s (%s)", item.label or item.file, item.file) end
    end
    if not submitted then
        item.deliveryFailed = true
        if item.backend == "OGG" then EC:Log("语音播放失败：%s", item.file) end
        local generation = self.generation
        C_Timer.After(0, function() if Voice.generation == generation then Voice:Pump() end end)
        return
    end
    self.playing, self.currentItem = true, item
    self.currentHandle = handle
    local generation = self.generation
    -- Local pacing only. TTS exposes no per-addon completion/stop handle;
    -- cancelling an EVC item never calls the global StopSpeakingText API.
    C_Timer.After((duration or 0.7) + self.gap, function()
        if Voice.generation ~= generation then return end
        Voice.playing, Voice.currentHandle, Voice.currentItem = false, nil, nil
        Voice:Pump()
    end)
end

function Voice:Enqueue(definition, kind, force, interrupt, owner, special)
    if force and EC.state.dbReady and not EC.db.enabled then
        print("|cffffc857[奶龙打地鼠]|r 插件总开关已关闭，请先开启再测试声音。")
        return false
    end
    if not definition or not CanPlay(kind, force) then return false end
    if not self:CheckBackend(force) then return false end
    local item = { backend = self:GetBackend(), file = definition.file, duration = definition.duration, label = definition.label,
        kind = kind, force = force, owner = owner, special = special,
        snapshot = EC.Timeline and EC.Timeline.snapshot }
    if special == "CANCEL" and not force and EC.CastTracker then
        item.castGeneration = EC.CastTracker.armGeneration
        item.castSessionStart = EC.CastTracker.sessionStartTime
        item.castWave = EC.CastTracker.currentWaveIndex
    end
    if not self:IsValid(item) then return false end
    if interrupt then
        self:Stop(false) -- Don't delete unrelated still-valid skill reminders.
        table.insert(self.queue, 1, item)
    else table.insert(self.queue, item) end
    while #self.queue > 24 do table.remove(self.queue) end
    self:Pump()
    return item.deliveryFailed ~= true
end

function Voice:PlaySkill(skillKey, force, owner)
    if EC.Features and not EC.Features:SkillEnabled(skillKey) then return false end
    return self:Enqueue(self.SKILL_FILES[skillKey], "NORMAL", force, false, owner)
end

function Voice:PlaySpecial(key, force, interrupt, owner)
    if interrupt == nil then interrupt = key == "CANCEL" or key == "EARLY" end
    return self:Enqueue(self.SPECIAL_FILES[key], "CORRECTION", force, interrupt, owner, key)
end
