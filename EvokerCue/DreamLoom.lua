local _, EC = ...
local D = { rulesVersion = "dreamloom-fixed-v1", objectiveVersion = "balls-breaths-combos-earlyY-lateB-lateR-v1",
    inputRevision = 0, defaults = { maxStates = 2000000, sliceStates = 64, sliceMs = 4, maxCpuMs = 20000 } }
EC.DreamLoom = D
D.patterns = { BBY = {"B", "B", "Y"}, BYB = {"B", "Y", "B"}, BBF = {"B", "B", "F"} }
D.keys = { B="DREAM_BREATH", Y="BALL", F="FLOWER", S="STASIS", R="RELEASE_STASIS" }
D.names = { DREAM_BREATH="梦境吐息", BALL="溜溜球", FLOWER="花", STASIS="静滞", RELEASE_STASIS="释放静滞" }
function D:Clock(t) return string.format("%02d:%02d", math.floor(t / 60), t % 60) end
function D:ParseEnd(text)
    local m,s = tostring(text or ""):match("^%s*(%d+):(%d%d)%s*$")
    m,s = tonumber(m),tonumber(s)
    if not m or not s or s >= 60 then return nil, "请填写战斗结束时间，例如 06:32。" end
    return m*60+s
end
function D:CheckRequest(r)
    if type(r) ~= "table" or type(r.fightEnd) ~= "number" or r.fightEnd < 1 or r.fightEnd > 1800
        or r.fightEnd % 1 ~= 0 then return "战斗结束时间须为 00:01 至 30:00 的整秒。" end
    if r.mode ~= "STRICT_BBY" and r.mode ~= "FLEX_TOTAL" then return "组合模式无效。" end
    if r.tickSeconds and r.tickSeconds ~= 1 then return "固定模型仅支持 1 秒网格。" end
    if r.rulesVersion and r.rulesVersion ~= self.rulesVersion then return "模型版本不一致。" end
    if r.objectiveVersion and r.objectiveVersion ~= self.objectiveVersion then return "优化目标版本不一致。" end
    if type(r.stasisTimes) ~= "table" then return "缺少静滞锚点。" end
    if r.initial and ((r.initial.breathDebt or 0) ~= 0 or (r.initial.ballRemaining or 9) ~= 9) then return "固定模型起手为两层喷、球剩余 9 秒。" end
    if r.rules then return "此版本不接受自定义机制参数。" end
    local previous
    for i,t in ipairs(r.stasisTimes) do
        if type(t) ~= "number" or t < 0 or t % 1 ~= 0 or t >= r.fightEnd then return "第 "..i.." 波静滞不在战斗内整秒时间上。" end
        if previous and t <= previous then return "静滞锚点重复或未按时间排序（第 "..i.." 波）。" end
        if previous and t-previous < 90 then return "第 "..i.." 波静滞间隔不足固定预校验的 90 秒。" end
        previous=t
    end
end
function D:Better(a,b)
    if not b then return true end
    for i=1,7 do if a[i] ~= b[i] then return a[i] > b[i] end end
    return false
end
function D:InputsChanged()
    if EC.Features and not EC.Features:DreamLoomEnabled() then return end
    self.inputRevision = self.inputRevision + 1
    if self.UI then self.UI:Invalidate() end
end
function D:IdentityKey(identity)
    local parts={identity.mode or "", identity.game and identity.game.fullName or ""}
    for _,c in ipairs(identity.candidates or {}) do parts[#parts+1]=c.value end
    return table.concat(parts,"\031")
end
