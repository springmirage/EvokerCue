local addonName, EC = ...

local Parser = {}
EC.Parser = Parser

local function Trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$") or ""
end

local function PlainFind(haystack, needle)
    if haystack == "" or needle == "" then
        return false
    end
    return haystack:find(needle, 1, true) ~= nil
end

-- Single-character shorthand is a whole skill token, never a substring of
-- another spell, player name or note. Full existing aliases keep their rules.
local function FindAlias(text, alias, from)
    local first, last = text:find(alias, from or 1, true)
    while first do
        if alias ~= "球" and alias ~= "花" then return first, last end
        local before, after = text:sub(first-1,first-1), text:sub(last+1,last+1)
        if (first == 1 or before:match("[%s%p]")) and (last == #text or after:match("[%s%p]")) then return first, last end
        first, last = text:find(alias, last+1, true)
    end
end

local function StripMarkup(text)
    if type(text) ~= "string" then
        return ""
    end

    text = text:gsub("||", "|")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    -- Personal MRT assignments may wrap skills in angle brackets so other
    -- timeline/TTS addons ignore them. EvokerCue deliberately recognizes them.
    text = text:gsub("<", " ")
    text = text:gsub(">", " ")
    text = text:gsub("：", ":")
    text = text:gsub("，", " ")
    text = text:gsub("。", " ")
    text = text:gsub("；", " ")
    text = text:gsub("、", " ")
    text = text:gsub("—", " ")
    text = text:gsub("–", " ")
    text = text:gsub("%s+", " ")
    return Trim(text)
end

local SKILL_DEFS = {
    BALL = {
        key = "BALL", name = "溜溜球",
        aliases = { "时空畸体", "溜溜球", "球" },
        ids = { [373861] = true }, primaryID = 373861,
        color = { 0.41, 0.79, 0.68 },
    },
    FLOWER = {
        key = "FLOWER", name = "翡翠之花",
        aliases = { "翡翠之花", "花" },
        ids = { [355913] = true }, primaryID = 355913,
        color = { 0.41, 0.79, 0.68 },
    },
    RELEASE_STASIS = {
        key = "RELEASE_STASIS",
        name = "释放静滞",
        aliases = { "释放静滞", "Release Stasis" },
        ids = { [370562] = true, [370564] = true },
        primaryID = 370564,
        iconFallbackID = 370537,
        color = { 1.00, 0.76, 0.18 },
    },
    DREAM_BREATH = {
        key = "DREAM_BREATH",
        name = "梦境吐息",
        aliases = { "梦境吐息", "绿喷", "Dream Breath" },
        ids = { [355936] = true, [382614] = true },
        primaryID = 355936,
        color = { 0.25, 1.00, 0.48 },
    },
    REWIND = {
        key = "REWIND",
        name = "回溯",
        aliases = { "回溯", "Rewind" },
        ids = { [363534] = true, [384089] = true },
        primaryID = 363534,
        color = { 1.00, 0.76, 0.18 },
    },
    ZEPHYR = {
        key = "ZEPHYR",
        name = "微风",
        aliases = { "微风", "Zephyr" },
        ids = { [374227] = true },
        primaryID = 374227,
        color = { 1.00, 0.76, 0.18 },
    },
    SPATIAL_PARADOX = {
        key = "SPATIAL_PARADOX",
        name = "空间悖论",
        aliases = { "空间悖论", "悖论", "Spatial Paradox" },
        ids = { [406732] = true, [406789] = true },
        primaryID = 406732,
        color = { 1.00, 0.76, 0.18 },
    },
    TIME_SPIRAL = {
        key = "TIME_SPIRAL",
        name = "时间螺旋",
        aliases = { "时间螺旋", "Time Spiral" },
        ids = { [374968] = true },
        primaryID = 374968,
        color = { 1.00, 0.76, 0.18 },
    },
    STASIS = {
        key = "STASIS",
        name = "静滞",
        aliases = { "静滞", "Stasis" },
        ids = { [370537] = true },
        primaryID = 370537,
        color = { 1.00, 0.76, 0.18 },
    },
}

-- Release Stasis must precede Stasis because the Chinese text contains 静滞.
local SKILL_PRIORITY = {
    "RELEASE_STASIS",
    "DREAM_BREATH",
    "REWIND",
    "ZEPHYR",
    "SPATIAL_PARADOX",
    "TIME_SPIRAL",
    "STASIS",
    "BALL",
    "FLOWER",
}

Parser.SKILL_DEFS = SKILL_DEFS
Parser.SKILL_PRIORITY = SKILL_PRIORITY
Parser.StripMarkup = StripMarkup

function Parser:GetEnabledSkillKeys()
    local keys = {}
    for _, key in ipairs(SKILL_PRIORITY) do
        if not EC.Features or EC.Features:SkillEnabled(key) then keys[#keys + 1] = key end
    end
    return keys
end

function Parser:GetAliasSignature()
    local configured = EC.db and EC.db.timeline and EC.db.timeline.customAliases or {}
    local parts = {}
    for _, key in ipairs(SKILL_PRIORITY) do
        local value = type(configured[key]) == "string" and configured[key] or ""
        parts[#parts + 1] = key .. ":" .. #value .. ":" .. value
    end
    return table.concat(parts, "|")
end

function Parser:GetAliasIndex()
    local signature = self:GetAliasSignature()
    if self.aliasIndex and self.aliasIndex.signature == signature then return self.aliasIndex end
    local index = { signature = signature, entries = {}, issues = {} }
    local builtin, customs = {}, {}
    local configured = EC.db and EC.db.timeline and EC.db.timeline.customAliases or {}
    for _, key in ipairs(SKILL_PRIORITY) do
        for _, alias in ipairs(SKILL_DEFS[key].aliases) do
            builtin[alias:lower()] = key
            index.entries[#index.entries + 1] = { alias = alias:lower(), def = SKILL_DEFS[key], builtin = true }
        end
    end
    for _, key in ipairs(SKILL_PRIORITY) do
        local value = type(configured[key]) == "string" and configured[key] or ""
        value = value:gsub("，", ","):gsub("；", ";")
        for alias in value:gmatch("[^,;]+") do
            if alias:find("[\r\n]") then
                index.issues[#index.issues + 1] = { code = "INVALID_CUSTOM_ALIAS", alias = alias,
                    text = SKILL_DEFS[key].name .. "的额外别名含换行，该项不参与解析。请改用中英文逗号或分号分隔；内置名称仍然有效。" }
            else
                alias = Trim(alias):lower()
                if alias ~= "" then
                    customs[alias] = customs[alias] or {}
                    customs[alias][key] = true
                end
            end
        end
    end
    local keys = {}
    for alias in pairs(customs) do keys[#keys + 1] = alias end
    table.sort(keys)
    for _, alias in ipairs(keys) do
        local owners, key = 0, nil
        for owner in pairs(customs[alias]) do owners = owners + 1; key = owner end
        local code
        if owners > 1 then code = "AMBIGUOUS_CUSTOM_ALIAS"
        elseif builtin[alias] and builtin[alias] ~= key then code = "BUILTIN_ALIAS_COLLISION"
        elseif alias:find("[<>{}|/]") then code = "INVALID_CUSTOM_ALIAS" end
        -- Reject cross-skill overlaps with built-ins as well: a custom phrase
        -- must never absorb another skill's official name or Release Stasis.
        if not code then
            for built, owner in pairs(builtin) do
                if owner ~= key and FindAlias(alias, built) then code = "BUILTIN_ALIAS_COLLISION"; break end
            end
        end
        if code then
            index.issues[#index.issues + 1] = { code = code, alias = alias,
                text = "自定义别名「" .. alias .. "」冲突或含保留标记（" .. code .. "），该自定义别名不参与解析；内置名称仍然有效。" }
        elseif not builtin[alias] then
            index.entries[#index.entries + 1] = { alias = alias, def = SKILL_DEFS[key] }
        end
    end
    table.sort(index.entries, function(a, b)
        if #a.alias ~= #b.alias then return #a.alias > #b.alias end
        return a.alias < b.alias
    end)
    self.aliasIndex = index
    return index
end

function Parser:SetCustomAliases(values)
    for _, key in ipairs(SKILL_PRIORITY) do
        if type(values[key]) == "string" then EC.db.timeline.customAliases[key] = values[key] end
    end
    self.aliasIndex = nil
    EC:RefreshCurrentNote("自定义技能别名", true, false)
    return self:GetAliasIndex().issues
end

local function FetchSpellName(spellID)
    if not spellID then
        return nil
    end

    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end

    if _G.GetSpellInfo then
        local ok, name = pcall(_G.GetSpellInfo, spellID)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end

    return nil
end

local function FetchSpellTexture(spellID)
    if not spellID then
        return nil
    end

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

local function ResolveDefinitionTexture(def, spellID)
    return FetchSpellTexture(spellID)
        or FetchSpellTexture(def and def.primaryID)
        or FetchSpellTexture(def and def.iconFallbackID)
        or 134400
end

local function MatchDefinitionByText(text)
    local plain = StripMarkup(text)
    local lower = plain:lower()

    for _, key in ipairs(SKILL_PRIORITY) do
        local def = SKILL_DEFS[key]
        for _, alias in ipairs(def.aliases) do
            if FindAlias(lower, alias:lower()) then
                return def
            end
        end
    end

    return nil
end

local function MatchDefinitionBySpellID(spellID)
    for _, key in ipairs(SKILL_PRIORITY) do
        local def = SKILL_DEFS[key]
        if def.ids[spellID] then
            return def
        end
    end

    local spellName = FetchSpellName(spellID)
    if spellName then
        local def = MatchDefinitionByText(spellName)
        if def and def.key ~= "BALL" and def.key ~= "FLOWER" then return def end
    end

    return nil
end

local function ParseClock(raw)
    raw = Trim(raw):gsub("：", ":")
    if raw == "" then
        return nil, "EMPTY_TIME"
    end

    local lower = raw:lower()
    if raw:find(",", 1, true)
        or lower:find("phase", 1, true)
        or lower:match("p%d")
        or raw:find("阶段", 1, true)
    then
        return nil, "PHASE_FORMAT_UNSUPPORTED"
    end

    local minuteText, secondText = raw:match("^(%d+):(%d+%.?%d*)$")
    if not minuteText or not secondText then
        return nil, "INVALID_TIME"
    end

    local minutes = tonumber(minuteText)
    local seconds = tonumber(secondText)
    if not minutes or not seconds or seconds >= 60 then
        return nil, "INVALID_TIME"
    end

    return minutes * 60 + seconds, nil
end

Parser.ParseClock = ParseClock

local function NormalizeSpellTokens(text)
    -- Normalize spell links before splitting assignments on '|'. Keep names and
    -- realm hyphens intact; never rewrite the player's source text in storage.
    return text:gsub("||", "|")
        :gsub("|Hspell:(%d+)[^|]*|h.-|h", "{spell:%1}")
        :gsub("{[Ss][Pp][Ee][Ll][Ll][Ii][Dd]%s*[:=]%s*(%d+)%s*}", "{spell:%1}")
        :gsub("%f[%a][Ss][Pp][Ee][Ll][Ll][Ii][Dd]%s*[:=]%s*(%d+)", "{spell:%1}")
        :gsub("(%s)[Ss][Pp][Ee][Ll][Ll]%s*[:=]%s*(%d+)", "%1{spell:%2}")
end

local function ExtractTimeAndContent(rawLine)
    local normalized = NormalizeSpellTokens(tostring(rawLine or ""):gsub("^\239\187\191", ""):gsub("：", ":"))
    local before, payload, after = normalized:match("^(.-){[Tt][Ii][Mm][Ee]:([^}]+)}(.*)$")

    if payload then
        local seconds, errorCode = ParseClock(payload)
        if not seconds then
            return nil, nil, errorCode
        end

        local content = Trim((before or "") .. " " .. (after or ""))
        return seconds, content, nil
    end

    -- Simple format: 0:05 Name Skill / 00:05.1 Name Skill / 1:00 Name Skill.
    local timeToken, content = normalized:match("^%s*(%d+:%d+%.?%d*)%s+(.+)$")
    if timeToken then
        local seconds, errorCode = ParseClock(timeToken)
        if not seconds then
            return nil, nil, errorCode
        end
        return seconds, Trim(content), nil
    end

    -- Also accept a plain MRT-style prefix without braces.
    timeToken, content = normalized:match("^%s*[Tt][Ii][Mm][Ee]%s*:%s*(%d+:%d+%.?%d*)%s+(.+)$")
    if timeToken then
        local seconds, errorCode = ParseClock(timeToken)
        return seconds, Trim(content), errorCode
    end

    return nil, nil, "NO_TIME"
end

local function IsASCIIDelimiter(byteValue)
    if not byteValue then
        return true
    end

    return byteValue == 9
        or byteValue == 10
        or byteValue == 13
        or byteValue == 32
        or byteValue == 44
        or byteValue == 46
        or byteValue == 47
        or byteValue == 58
        or byteValue == 59
        or byteValue == 91
        or byteValue == 93
        or byteValue == 40
        or byteValue == 41
        or byteValue == 123
        or byteValue == 125
        or byteValue == 124
end

local function ContentMatchesCandidate(cleanContent, candidateValue)
    candidateValue = StripMarkup(candidateValue)
    if cleanContent == "" or candidateValue == "" then
        return false
    end

    local searchFrom = 1
    while true do
        local startPos, endPos = cleanContent:find(candidateValue, searchFrom, true)
        if not startPos then
            return false
        end

        local beforeByte = startPos > 1 and cleanContent:byte(startPos - 1) or nil
        local afterByte = endPos < #cleanContent and cleanContent:byte(endPos + 1) or nil
        local skillFollows = false
        if not IsASCIIDelimiter(afterByte) then
            -- Keep "Tester静滞", but not "TesterTwo" or another realm/name.
            local suffix = cleanContent:sub(endPos + 1):lower()
            for _, entry in ipairs(Parser:GetAliasIndex().entries) do
                local alias = entry.alias
                    if suffix:sub(1, #alias) == alias:lower()
                        and IsASCIIDelimiter(suffix:byte(#alias + 1)) then
                        skillFollows = true
                    end
            end
        end
        if IsASCIIDelimiter(beforeByte) and (IsASCIIDelimiter(afterByte) or skillFollows) then
            return true, startPos, endPos
        end

        searchFrom = endPos + 1
    end
end

local function MatchPlayerCandidate(cleanContent, candidates)
    for _, candidate in ipairs(candidates or {}) do
        if ContentMatchesCandidate(cleanContent, candidate.value) then
            return candidate
        end
    end
    return nil
end

local function HasAssignmentTag(content, tagText)
    if type(content) ~= "string" or type(tagText) ~= "string" or tagText == "" then
        return false
    end

    -- Assignment tags use ASCII braces only.
    return content:find("{" .. tagText .. "}", 1, true) ~= nil
end

local function BuildSharedCandidate(identity, source)
    local game = identity and identity.game or {}
    local value = Trim(game.shortName)
    if value == "" then
        value = Trim(game.fullName)
    end
    if value == "" then
        return nil
    end
    return { value = value, source = source }
end

-- Personal names and current-player class/role selectors own accepted entries.
local function MatchAssignmentTarget(content, cleanContent, identity)
    local direct = MatchPlayerCandidate(cleanContent, identity and identity.candidates or {})
    if direct then return direct end
    local game = identity and identity.game or {}
    -- Shared selectors apply only when the current player belongs to the target.
    if game.classFile == "EVOKER" and HasAssignmentTag(content, "唤魔师") then
        return BuildSharedCandidate(identity, "CLASS_TAG")
    end
    if game.role == "HEALER" and HasAssignmentTag(content, "治疗") then
        return BuildSharedCandidate(identity, "ROLE_TAG")
    end
    return nil
end

local function SplitAssignments(content)
    -- Strip display escapes before splitting: texture paths can contain slashes.
    local text = content:gsub("||", "|"):gsub("|T.-|t", ""):gsub("|A.-|a", "")
        :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        :gsub("／", "/"):gsub("；", ";")
        :gsub("：", ":"):gsub("，", " "):gsub("。", " "):gsub("、", " ")
        :gsub("—", " "):gsub("–", " "):gsub("%s+", " ")
    local segments, start, depth = {}, 1, 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "<" or ch == "{" then depth = depth + 1
        elseif ch == ">" or ch == "}" then depth = math.max(0, depth - 1)
        elseif depth == 0 and (ch == "/" or ch == ";" or ch == "|") then
            segments[#segments + 1] = Trim(text:sub(start, i - 1))
            start = i + 1
        end
    end
    segments[#segments + 1] = Trim(text:sub(start))
    return segments
end

local function MaskRange(text, first, last)
    return text:sub(1, first - 1) .. string.rep(" ", last - first + 1) .. text:sub(last + 1)
end

local function GetSelectorText(content)
    -- Skill wrappers cannot select a character whose name equals a skill name.
    return content:gsub("<.->", function(value) return string.rep(" ", #value) end)
        :gsub("{[Ss][Pp][Ee][Ll][Ll]:%d+[^}]*}", function(value) return string.rep(" ", #value) end)
end

local function ResolveSkills(content, selectorText, identity)
    -- Remove this player's selectors before looking for skill names. A custom
    -- character name containing "静滞" must not manufacture a Stasis event.
    local remaining = content
    for _, candidate in ipairs(identity.candidates or {}) do
        while true do
            local found, first, last = ContentMatchesCandidate(selectorText, candidate.value)
            if not found then break end
            remaining = MaskRange(remaining, first, last)
            selectorText = MaskRange(selectorText, first, last)
        end
    end
    remaining = StripMarkup(remaining)
    remaining = remaining:gsub("{([^}]+)}", function(tag)
        if MatchAssignmentTarget("{" .. tag .. "}", "", identity) then return string.rep(" ", #tag + 2) end
        return "{" .. tag .. "}"
    end)

    local skills, byKey, firstID = {}, {}, nil
    local function Add(def, spellID, position)
        if not def then return end
        local item = byKey[def.key]
        if item then item.position = math.min(item.position, position); return end
        item = { def = def, spellID = spellID, position = position }
        skills[#skills + 1], byKey[def.key] = item, item
    end
    local from = 1
    -- A bare spell ID is allowed only when it is the entire skill payload,
    -- after the matched owner has been removed. Unknown IDs remain unsupported.
    local bareID = Trim(remaining):match("^%-?%s*(%d+)%s*$")
    if bareID and MatchDefinitionBySpellID(tonumber(bareID)) then
        remaining = "{spell:" .. bareID .. "}"
    end
    while true do
        local first, last, idText = remaining:find("{[Ss][Pp][Ee][Ll][Ll]:(%d+)[^}]*}", from)
        if not first then break end
        local id = tonumber(idText)
        firstID = firstID or id
        Add(MatchDefinitionBySpellID(id), id, first)
        remaining = MaskRange(remaining, first, last)
        from = last + 1
    end
    -- Mask longer aliases first (Release Stasis before Stasis), preserving byte
    -- positions so several distinct skills retain their written order.
    for _, entry in ipairs(Parser:GetAliasIndex().entries) do
        local def, alias = entry.def, entry.alias
            while true do
                local first, last = FindAlias(remaining:lower(), alias:lower())
                if not first then break end
                Add(def, def.primaryID, first)
                remaining = MaskRange(remaining, first, last)
            end
    end
    -- Unexplained words may be another owner or an unsupported instruction.
    -- Do not infer ownership even when only one supported skill was found.
    local ambiguous = #skills > 0 and remaining:find("[%w\128-\255]") ~= nil
    table.sort(skills, function(a, b) return a.position < b.position end)
    return skills, firstID, ambiguous
end

function Parser:GetSkillDefinition(skillKey)
    return SKILL_DEFS[skillKey]
end

function Parser:GetSkillTexture(skillKey)
    local def = SKILL_DEFS[skillKey]
    if not def then
        return 134400
    end
    return ResolveDefinitionTexture(def, def.primaryID)
end

-- Read-only assignment inspection for the offline model, using the same
-- skill aliases and identity matching as combat parsing.
function Parser:InspectDreamLoomLine(rawLine, identity)
    local seconds, content, timeError = ExtractTimeAndContent(rawLine)
    if not seconds and timeError == "NO_TIME" and (rawLine:match("^%s*#") or rawLine:match("^%s*%-%-") or rawLine:match("^%s*//")) then
        return nil, {}, timeError
    end
    local own = {}
    for _, segment in ipairs(SplitAssignments(content or rawLine)) do
        local selector = GetSelectorText(segment)
        local candidate = MatchAssignmentTarget(segment, selector, identity)
        if candidate then
            local skills, _, ambiguous = ResolveSkills(segment, selector, identity)
            local keys = {}
            for _, skill in ipairs(skills) do keys[#keys + 1] = skill.def.key end
            own[#own + 1] = { keys = keys, ambiguous = ambiguous, playerName = candidate.value }
        end
    end
    return seconds, own, timeError
end

local function IsArrangementCandidate(text, identity, timed)
    local bare = Trim(StripMarkup(text)):lower()
    for _, entry in ipairs(Parser:GetAliasIndex().entries) do
        if bare == entry.alias then return true end -- A bare supported skill may be a truncated arrangement.
    end
    return timed or MatchAssignmentTarget(text, GetSelectorText(text), identity) ~= nil
        or text:find("^%s*%d+[:%-]") ~= nil or text:find("{time:", 1, true) ~= nil
        or text:find("{spell:", 1, true) ~= nil or text:find("|Hspell:", 1, true) ~= nil
end

function Parser:BuildDomainEvidence(result, identity, otherOwners)
    -- Completeness means the accepted personal entries, not the entire raid note.
    -- Ignored prose, owners, selectors and unknown spells never veto those entries.
    result.integrity.domains = {}
    for key in pairs(SKILL_DEFS) do
        result.integrity.domains[key] = {state="COMPLETE", candidates={}}
    end
end

local function OwnPayloads(segment, identity)
    local text = StripMarkup(segment)
    local starts = {}
    for _, candidate in ipairs(identity.candidates or {}) do
        local from = 1
        while from <= #text do
            local found, first, last = ContentMatchesCandidate(text:sub(from), candidate.value)
            if not found then break end
            starts[#starts + 1] = { first = first + from - 1, last = last + from - 1, candidate = candidate }
            from = last + from
        end
    end
    local function AddSharedSelector(tag, source)
        local candidate = BuildSharedCandidate(identity, source)
        if not candidate then return end
        local from = 1
        while true do
            local first, last = text:find(tag, from, true)
            if not first then break end
            starts[#starts + 1] = {first=first, last=last, candidate=candidate}
            from = last + 1
        end
    end
    if identity.game and identity.game.classFile == "EVOKER" then
        AddSharedSelector("{唤魔师}", "CLASS_TAG")
    end
    if identity.game and identity.game.role == "HEALER" then
        AddSharedSelector("{治疗}", "ROLE_TAG")
    end
    table.sort(starts, function(a,b) if a.first ~= b.first then return a.first < b.first end return a.last > b.last end)
    local result, lastEnd = {}, 0
    for _, start in ipairs(starts) do
        if start.first > lastEnd and start.candidate then
            result[#result + 1] = {text=text:sub(start.last + 1), candidate=start.candidate}
            lastEnd = start.last
        end
    end
    return result
end

local function ReadOwnedSkills(payload)
    local skills, seen = {}, {}
    local remaining = Trim(payload)
    while remaining ~= "" do
        remaining = remaining:gsub("^[%s:,%+%-]+", "")
        -- Raid markers are decoration, not another assignment owner.
        local markerEnd = remaining:match("^{rt%d+}()")
        if markerEnd then remaining = Trim(remaining:sub(markerEnd)) end
        local first, last, digits = remaining:find("^{[Ss][Pp][Ee][Ll][Ll]:(%d+)[^}]*}")
        local def, spellID
        if first then
            spellID = tonumber(digits); def = MatchDefinitionBySpellID(spellID)
            -- Unknown spell markup is ignored; it cannot name a different owner.
        else
            local bare = remaining:match("^(%d+)%s*$")
            if bare then def=MatchDefinitionBySpellID(tonumber(bare));spellID=tonumber(bare);last=#remaining end
            if not def then
                for _, entry in ipairs(Parser:GetAliasIndex().entries) do
                    local a,b = FindAlias(remaining:lower(),entry.alias:lower())
                    if a == 1 then def=entry.def;spellID=def.primaryID;last=b;break end
                end
            end
            -- A foreign/unknown word terminates this owner's payload. In a
            -- shared line it may be the next player; never scan past it for skills.
            if not def then break end
        end
        if def and not seen[def.key] then
            seen[def.key]=true;skills[#skills+1]={def=def,spellID=spellID}
        end
        remaining = Trim(remaining:sub(last + 1))
    end
    return skills
end

function Parser:ParseLineEvents(rawLine, lineNumber, identity, otherOwners)
    local seconds, content, timeError = ExtractTimeAndContent(rawLine)
    local events, extra = {}, {issues={},coverage={},evidence={},time=seconds,lineNumber=lineNumber,rawLine=rawLine}
    local body = content or NormalizeSpellTokens(rawLine):gsub("^%s*{time:[^}]*}%s*", ""):gsub("^%s*%d+[:%-%d%.]*%s+", "")
    local foundOwnSkill, emitted = false, {}
    for _, segment in ipairs(SplitAssignments(body)) do
        local parsed = false
        for _, payload in ipairs(OwnPayloads(segment, identity)) do
            for _, skill in ipairs(ReadOwnedSkills(payload.text)) do
                foundOwnSkill = true
                if seconds then
                    local def = skill.def
                    extra.matchedPlayerName = payload.candidate.value
                    if not emitted[def.key] and (not EC.Features or EC.Features:SkillEnabled(def.key)) then
                        emitted[def.key] = true -- One event per skill/time/line, even with overlapping own selectors.
                        events[#events+1]={time=seconds,lineNumber=lineNumber,rawLine=rawLine,
                            content=segment,cleanContent=StripMarkup(segment),assignmentOrder=#events+1,
                            matchedPlayerName=payload.candidate.value,matchedPlayerSource=payload.candidate.source,
                            skillKey=def.key,skillName=def.name,spellID=skill.spellID,slotReliable=true,
                            texture=ResolveDefinitionTexture(def,skill.spellID),color=def.color,waveIndex=0}
                    end
                    parsed = true
                end
            end
        end
        local status = parsed and "PARSED_SELF" or "IGNORED"
        extra.coverage[#extra.coverage+1]=status
        extra.evidence[#extra.evidence+1]={status=status,text=segment,time=seconds}
    end
    if foundOwnSkill and not seconds then
        extra.issues[#extra.issues+1]={code="PERSONAL_TIME_UNPARSED",lineNumber=lineNumber,
            text=string.format("第 %d 行本人技能时间无法解析，已跳过该条。",lineNumber or 0)}
    end
    if foundOwnSkill and seconds then return events,nil,extra end
    return nil,"IGNORED",extra
end

function Parser:ParseLine(rawLine, lineNumber, identity)
    local events, errorCode, extra = self:ParseLineEvents(rawLine, lineNumber, identity)
    if not events then return nil, errorCode, extra end
    if #events == 1 then return events[1], nil, extra end
    -- Keep the single-event API explicit; callers must not silently lose skills.
    extra.events = events
    return nil, "MULTIPLE_EVENTS", extra
end

local function StableSortEvents(events)
    table.sort(events, function(a, b)
        if a.time ~= b.time then
            return a.time < b.time
        end
        if a.skillKey == "STASIS" and b.skillKey ~= "STASIS" then return true end
        if b.skillKey == "STASIS" and a.skillKey ~= "STASIS" then return false end
        if (a.lineNumber or 0) ~= (b.lineNumber or 0) then
            return (a.lineNumber or 0) < (b.lineNumber or 0)
        end
        return (a.assignmentOrder or 0) < (b.assignmentOrder or 0)
    end)

    for index, event in ipairs(events) do
        event.sequence = index
    end
end

function Parser:CompileWaves(events)
    StableSortEvents(events)

    local waves = {}
    local currentWave = nil

    for _, event in ipairs(events) do
        if event.skillKey == "STASIS" then
            currentWave = {
                index = #waves + 1,
                stasisTime = event.time,
                nextStasisTime = nil,
                events = {},
                breaths = {},
            }
            table.insert(waves, currentWave)
            event.waveIndex = currentWave.index
            table.insert(currentWave.events, event)
        elseif currentWave then
            event.waveIndex = currentWave.index
            table.insert(currentWave.events, event)

            if event.skillKey == "DREAM_BREATH" then
                table.insert(currentWave.breaths, event)
            end
        else
            event.waveIndex = 0
        end
    end

    for index, wave in ipairs(waves) do
        local nextWave = waves[index + 1]
        wave.nextStasisTime = nextWave and nextWave.stasisTime or nil
        wave.breathLimit = #wave.breaths

        for breathIndex, breathEvent in ipairs(wave.breaths) do
            breathEvent.breathIndex = breathIndex
            breathEvent.breathLimit = wave.breathLimit
        end
    end

    return waves
end

function Parser:BuildResult(noteText, identity, sourceIssues, deduplicateAfterLine)
    identity = identity or { candidates = {}, mode = "AUTO", game = {} }

    local result = {
        ok = false,
        status = "INIT",
        statusText = "尚未解析",
        identityMode = identity.mode,
        gamePlayerName = identity.game and identity.game.fullName or "",
        matchedPlayerName = nil,
        matchedPlayerSource = nil,
        matchedCandidateCounts = {},
        events = {},
        waves = {},
        waveQuotaText = "-",
        counts = {},
        warnings = {},
        parseIssues = {},
        integrity = { state="UNKNOWN", scope="SUPPORTED_SYNTAX_AND_CURRENT_IDENTITY", lines={}, unknownLines=0, partialLines=0, coveredLines=0 },
        stats = {
            totalLines = 0,
            timedLines = 0,
            playerTimedLines = 0,
            phaseLinesSkipped = 0,
            unrecognizedPlayerLines = 0,
            playerMismatchLines = 0,
            deduplicatedEvents = 0,
        },
    }

    for _, key in ipairs(SKILL_PRIORITY) do
        result.counts[key] = 0
    end
    for _, issue in ipairs(sourceIssues or {}) do result.parseIssues[#result.parseIssues + 1] = issue end
    for _, issue in ipairs(self:GetAliasIndex().issues) do result.parseIssues[#result.parseIssues + 1] = issue end

    if type(noteText) ~= "string" or Trim(noteText) == "" then
        result.status = "NO_NOTE"
        result.statusText = "当前战术板为空"
        if EC.PlanGuard then EC.PlanGuard:Validate(result) end
        return result
    end

    if type(identity.candidates) ~= "table" or #identity.candidates == 0 then
        result.status = "NO_PLAYER_NAME"
        result.statusText = "无法取得当前游戏角色名"
        return result
    end

    -- All parsed events already belong to this player. Canonical skill keys
    -- merge aliases and alternate spell IDs; numeric times stay exact.
    -- Keep the team event (and its original line) when the personal source
    -- repeats it. Repetitions within either source still reach PlanGuard.
    local teamEvents = {}
    local function IsCrossSourceDuplicate(event, lineNumber)
        if not deduplicateAfterLine then return false end
        local atTime = teamEvents[event.time]
        if lineNumber > deduplicateAfterLine then
            return atTime and atTime[event.skillKey] == true
        end
        if not atTime then
            atTime = {}
            teamEvents[event.time] = atTime
        end
        atTime[event.skillKey] = true
        return false
    end

    local lineNumber = 0
    local coverage = result.integrity
    local otherOwners = {} -- Name/own-Evoker matching needs no roster or other-class inference.
    for line in (noteText .. "\n"):gmatch("(.-)\n") do
        lineNumber = lineNumber + 1
        line = line:gsub("\r$", "")
        result.stats.totalLines = result.stats.totalLines + 1

        local events, errorCode, extra = self:ParseLineEvents(line, lineNumber, identity, otherOwners)
        local status = "COVERED"
        local plain = Trim(line:gsub("^\239\187\191", ""))
        if plain == "" then status = "BLANK"
        elseif errorCode == "NO_TIME" and (plain:match("^#") or plain:match("^%-%-") or plain:match("^//")) then status = "COMMENT"
        elseif not extra or not extra.coverage or #extra.coverage == 0 then
            status = IsArrangementCandidate(plain, identity, false) and (errorCode == "NO_TIME" and "UNKNOWN" or "PARTIAL") or "NOTE"
        else
            for _, segmentStatus in ipairs(extra.coverage) do
                if segmentStatus == "PARTIAL" then status = "PARTIAL"; break
                elseif segmentStatus == "UNKNOWN" then status = "UNKNOWN" end
            end
        end
        coverage.lines[#coverage.lines+1] = {lineNumber=lineNumber,status=status,segments=extra and extra.coverage,
            selfAssignment = extra and extra.matchedPlayerName ~= nil or false,
            evidence=(status ~= "COMMENT" and status ~= "BLANK") and extra and extra.evidence or {{status=status,text=line}}}
        if status == "PARTIAL" then coverage.partialLines=coverage.partialLines+1
        elseif status == "UNKNOWN" then coverage.unknownLines=coverage.unknownLines+1
        else coverage.coveredLines=coverage.coveredLines+1 end
        for _, issue in ipairs(extra and extra.issues or {}) do
            result.parseIssues[#result.parseIssues + 1] = issue
        end
        if events then
            result.stats.timedLines = result.stats.timedLines + 1
            result.stats.playerTimedLines = result.stats.playerTimedLines + 1
            for _, event in ipairs(events) do
                if IsCrossSourceDuplicate(event, lineNumber) then
                    result.stats.deduplicatedEvents = result.stats.deduplicatedEvents + 1
                else
                    table.insert(result.events, event)
                    result.counts[event.skillKey] = (result.counts[event.skillKey] or 0) + 1
                    result.matchedCandidateCounts[event.matchedPlayerName] = (result.matchedCandidateCounts[event.matchedPlayerName] or 0) + 1
                end
            end
        elseif errorCode == "PHASE_FORMAT_UNSUPPORTED" then
            result.stats.phaseLinesSkipped = result.stats.phaseLinesSkipped + 1
        elseif errorCode == "INVALID_TIME" or errorCode == "EMPTY_TIME" then
            result.parseIssues[#result.parseIssues + 1] = {
                code = "INVALID_TIME", lineNumber = lineNumber,
                text = string.format("第 %d 行时间无效，请使用 00:01 或 {time:0:01}。", lineNumber),
            }
        elseif errorCode == "UNSUPPORTED_SKILL" or errorCode == "AMBIGUOUS_ASSIGNMENT" then
            result.stats.timedLines = result.stats.timedLines + 1
            result.stats.playerTimedLines = result.stats.playerTimedLines + 1
            result.stats.unrecognizedPlayerLines = result.stats.unrecognizedPlayerLines + 1
            if extra and extra.matchedPlayerName then
                result.matchedCandidateCounts[extra.matchedPlayerName] = (result.matchedCandidateCounts[extra.matchedPlayerName] or 0) + 1
            end
            if errorCode == "UNSUPPORTED_SKILL" and #result.warnings < 20 then
                table.insert(result.warnings, string.format(
                    "第 %d 行：识别到本人和时间，但技能不在支持列表：%s",
                    lineNumber,
                    extra and extra.cleanContent or line
                ))
            end
        elseif errorCode == "PLAYER_MISMATCH" then
            result.stats.timedLines = result.stats.timedLines + 1
            result.stats.playerMismatchLines = result.stats.playerMismatchLines + 1
        end
    end

    coverage.state = coverage.partialLines > 0 and "PARTIAL" or coverage.unknownLines > 0 and "UNKNOWN" or "COMPLETE"
    self:BuildDomainEvidence(result, identity, otherOwners)
    local bestCandidate = nil
    local bestCount = -1
    for _, candidate in ipairs(identity.candidates) do
        local count = result.matchedCandidateCounts[candidate.value] or 0
        if count > bestCount then
            bestCount = count
            bestCandidate = candidate
        end
    end
    if bestCandidate and bestCount > 0 then
        result.matchedPlayerName = bestCandidate.value
        result.matchedPlayerSource = bestCandidate.source
    end

    result.waves = self:CompileWaves(result.events)

    local quotaParts = {}
    for _, wave in ipairs(result.waves) do
        table.insert(quotaParts, tostring(wave.breathLimit or 0))
    end
    result.waveQuotaText = #quotaParts > 0 and table.concat(quotaParts, " / ") or "-"

    if EC.PlanGuard then EC.PlanGuard:Validate(result) end

    if #result.events == 0 then
        result.status = "NO_SUPPORTED_EVENTS"
        result.statusText = identity.mode == "CUSTOM"
            and "自定义名称未匹配到支持技能"
            or "当前角色未匹配到支持技能"
        return result
    end

    if #result.waves == 0 then
        result.status = "NO_STASIS"
        result.ok = true -- Ordinary timed reminders do not require Stasis quotas.
        result.statusText = "已识别技能提醒；未提供静滞配额"
        return result
    end

    result.ok = true
    result.status = "READY"
    result.statusText = "已自动识别当前角色时间轴"
    return result
end
