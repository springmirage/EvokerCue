local _, EC = ...

local TTS = { warned = {}, defaults = { voice = "AUTO", rate = 0, volume = 100 } }
EC.TTS = TTS

-- Adapted from SFD core/tts.lua: voice 0, rate 0, volume 100 and the
-- SpeakText(voice, text, rate, volume, true) call. No SFD runtime is required.
-- SpeakText has no documented return value; StopSpeakingText is global.
-- Never claim an audible result or stop another addon's TTS.
local function Readable(value)
    return not (EC.IsSecret and EC:IsSecret(value))
end
local function Settings()
    return EC.db and EC.db.voice and EC.db.voice.tts or TTS.defaults
end
function TTS:GetVoices()
    if not (C_VoiceChat and C_VoiceChat.SpeakText and C_VoiceChat.GetTtsVoices) then return {}, "NO_API" end
    local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
    if not ok or not Readable(voices) or type(voices) ~= "table" then return {}, "NO_VOICES" end
    local result, seen = {}, {}
    for _, voice in ipairs(voices) do
        if Readable(voice) and type(voice) == "table" and Readable(voice.voiceID)
            and type(voice.voiceID) == "number" and Readable(voice.name) and type(voice.name) == "string"
            and not seen[voice.voiceID] then
            result[#result + 1] = { voiceID = voice.voiceID, name = voice.name }
            seen[voice.voiceID] = true
        end
    end
    return result, #result == 0 and "NO_VOICES" or nil
end
function TTS:GetVoice()
    local voices, reason = self:GetVoices()
    if #voices == 0 then return nil, reason end
    local configured = Settings().voice or "AUTO"
    if configured == "AUTO" then
        -- SFD uses ID 0. Prefer it only when the client actually exposes it;
        -- otherwise use the first enumerated voice, never invent an ID.
        for _, voice in ipairs(voices) do if voice.voiceID == 0 then return voice.voiceID, nil, voice.name end end
        return voices[1].voiceID, nil, voices[1].name
    end
    for _, voice in ipairs(voices) do if voice.voiceID == configured then return voice.voiceID, nil, voice.name end end
    return nil, "VOICE_MISSING"
end
function TTS:GetVoiceItems()
    local configured = Settings().voice or "AUTO"
    local items = { { value = "AUTO", text = "自动（默认音色）", selected = configured == "AUTO" } }
    local voices = self:GetVoices()
    for _, voice in ipairs(voices) do items[#items + 1] = { value = voice.voiceID, text = voice.name, selected = configured == voice.voiceID } end
    if #voices == 0 then items[#items + 1] = { text = "当前没有可用 TTS 音色", disabled = true } end
    return items
end
function TTS:GetVoiceLabel()
    local voice, reason, name = self:GetVoice()
    if voice == nil then return reason == "VOICE_MISSING" and "所选音色已不可用，请重新选择" or "当前 TTS 不可用，可切换内置语音包" end
    return (Settings().voice == "AUTO" and "自动：" or "") .. name
end
function TTS:Unavailable(reason, force)
    if force or not self.warned[reason] then
        self.warned[reason] = true
        print("|cffffc857[奶龙打地鼠]|r 内置TTS暂不可用，请重新选择音色或切换“内置语音包”。")
    end
    if EC.Log then EC:Log("TTS请求失败：%s", reason) end
    return false
end
function TTS:Ready(force)
    local voice, reason = self:GetVoice()
    if voice == nil then return self:Unavailable(reason, force) end
    return true
end
function TTS:Speak(text, force)
    local voice, reason = self:GetVoice()
    if voice == nil then return self:Unavailable(reason, force) end
    if type(text) ~= "string" or text == "" then return false end
    local d = Settings()
    local rate = math.max(-10, math.min(10, tonumber(d.rate) or 0))
    local volume = math.max(0, math.min(100, tonumber(d.volume) or 100))
    if volume <= 0 then return self:Unavailable("ZERO_VOLUME", force) end
    local ok, result = pcall(C_VoiceChat.SpeakText, voice, text, rate, volume, true)
    if not ok or not Readable(result) or result == false then return self:Unavailable("SUBMIT_FAILED", force) end
    -- The API is void: this means submitted, not confirmed audible playback.
    local chars = #text:gsub("[\128-\191]", "")
    local duration = math.max(0.7, (0.35 * chars + 0.35) / math.max(0.5, 1 + rate * 0.05))
    return true, duration
end
