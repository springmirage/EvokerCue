local _, EC = ...
local D=EC.DreamLoom
local function Normalize(text)
    return type(text)=="string" and text:gsub("\r\n","\n"):gsub("\r","\n") or nil
end
function D:CopyPlanData(value)
    if type(value)~="table" then return value end
    local copy={};for k,v in pairs(value) do copy[k]=self:CopyPlanData(v) end;return copy
end
local function Matches(record,text)
    return type(record)=="table" and type(record.baseText)=="string"
        and type(record.generatedText)=="string" and Normalize(record.generatedText)==Normalize(text)
end
local function Record(data)
    if not data or type(data.generatedText)~="string" or type(data.baseText)~="string" then return nil end
    return {baseText=data.baseText,generatedText=data.generatedText,generation=D:CopyPlanData(data.generation)}
end
function D:FindProvenance(plan,text)
    local data=plan.dreamLoom
    if not data then return end
    if Matches(data,text) then return Record(data) end
    if Matches(data.saved,text) then return self:CopyPlanData(data.saved) end
    for _,record in ipairs(data.history or {}) do
        if Matches(record,text) then return self:CopyPlanData(record) end
    end
end
function D:GetBaseForDraft(plan,text)
    local record=self:FindProvenance(plan,text)
    if not record then return text end
    return text==record.generatedText and record.baseText or Normalize(record.baseText)
end
function D:OnPlanSave(plan,text)
    if EC.Features and not EC.Features:DreamLoomEnabled() then return end
    local data=plan.dreamLoom
    if not data then return end
    local old=self:FindProvenance(plan,plan.text or "")
    local new=self:FindProvenance(plan,text)
    if text~=plan.text then
        data.history=data.history or {}
        table.insert(data.history,1,old or false)
        if #data.history>10 then table.remove(data.history) end
    end
    if new then new.baseText=Normalize(new.baseText);new.generatedText=text end
    data.saved=new
    if new then data.baseText,data.generatedText,data.generation=new.baseText,new.generatedText,self:CopyPlanData(new.generation) end
end
function D:RestoreProvenance(plan,text)
    if EC.Features and not EC.Features:DreamLoomEnabled() then return end
    local data=plan.dreamLoom
    if not data then return end
    local record=self:FindProvenance(plan,text)
    data.baseText=record and record.baseText
    data.generatedText=record and record.generatedText
    data.generation=record and record.generation
end
function D:GetSettings(plan)
    if EC.Features and not EC.Features:DreamLoomEnabled() then
        local data = plan.dreamLoom or {}
        return data.settings or {endText="",mode="STRICT_BBY"}, data
    end
    -- Optional per-plan metadata, not a second plan library.
    if not plan.dreamLoom then plan.dreamLoom={schemaVersion=1,settings={endText="",mode="STRICT_BBY"},settingsRevision=0} end
    local data=plan.dreamLoom
    data.settings=data.settings or {endText="",mode="STRICT_BBY"}
    return data.settings,data
end
function D:SetParameter(key,value)
    if EC.Features and not EC.Features:DreamLoomEnabled() then return false end
    local settings,data=self:GetSettings(EC.RaidaryPlan:GetDB())
    if settings[key]~=value then
        settings[key]=value;data.settingsRevision=(data.settingsRevision or 0)+1;self:InputsChanged()
    end
end
function D:Prepare()
    if EC.Features and not EC.Features:DreamLoomEnabled() then return nil,"DISABLED" end
    local plan=EC.RaidaryPlan:GetDB()
    local settings,data=self:GetSettings(plan)
    local fightEnd,errorText=self:ParseEnd(settings.endText)
    if not fightEnd then return nil,errorText end
    local identity=EC:GetPlayerIdentity()
    local player=identity.candidates and identity.candidates[1] and identity.candidates[1].value
    if not player or player=="" then return nil,"无法确认本人身份，请先检查设置。" end
    local source=EC.RaidaryPlan:GetDraft()
    local base=self:GetBaseForDraft(plan,source)
    if type(base)~="string" then return nil,"生成来源记录不完整，未修改草稿。" end
    if #base>64000 then return nil,"原稿超过 64 KB；请缩减用于计算的输入。" end
    local anchors,lineNumber={},0
    for line in (base.."\n"):gmatch("(.-)\n") do
        lineNumber=lineNumber+1
        local t,assignments=EC.Parser:InspectDreamLoomLine(line:gsub("\r$",""),identity)
        for _,assignment in ipairs(assignments) do
            if assignment.ambiguous then return nil,"第 "..lineNumber.." 行本人技能归属不明确，请用 / 分隔安排。" end
            if #assignment.keys==0 and t then return nil,"第 "..lineNumber.." 行本人技能未确认（含球/花时也需先移除安排）。不会静默覆盖。" end
            for _,key in ipairs(assignment.keys) do
                if key=="DREAM_BREATH" or key=="RELEASE_STASIS" or key=="BALL" or key=="FLOWER" then
                    return nil,"第 "..lineNumber.." 行已有本人喷/球/花/释放安排；第一版未实现固定这些施法，请先整理输入。"
                elseif key=="STASIS" then
                    if not t then return nil,"第 "..lineNumber.." 行静滞时间无效。" end
                    anchors[#anchors+1]=t
                end
            end
        end
    end
    if #anchors==0 then return nil,"未识别到本人的静滞开启时间，请前往战术板填写。" end
    local request={fightEnd=fightEnd,mode=settings.mode,stasisTimes=anchors,planID=plan.id,
        sourceText=source,baseText=base,sourceRevision=self.inputRevision,parameterRevision=data.settingsRevision or 0,
        endText=settings.endText,playerName=player,identityKey=self:IdentityKey(identity),aliasSignature=EC.Parser:GetAliasSignature(),
        rulesVersion=self.rulesVersion,objectiveVersion=self.objectiveVersion,tickSeconds=1}
    errorText=self:CheckRequest(request)
    if errorText then return nil,errorText end
    return request
end
function D:IsCurrent(request)
    if EC.Features and not EC.Features:DreamLoomEnabled() then return false end
    local plan=EC.RaidaryPlan:GetDB();local settings,data=self:GetSettings(plan)
    return request and request.planID==plan.id and request.sourceRevision==self.inputRevision
        and request.sourceText==EC.RaidaryPlan:GetDraft() and request.parameterRevision==(data.settingsRevision or 0)
        and request.endText==settings.endText and request.mode==settings.mode
        and request.identityKey==self:IdentityKey(EC:GetPlayerIdentity())
        and request.aliasSignature==EC.Parser:GetAliasSignature()
end
function D:TimelineText(request,result,includeStasis)
    local lines={}
    for _,event in ipairs(result.events or {}) do
        if includeStasis or event.skillKey~="STASIS" then
            lines[#lines+1]=self:Clock(event.start).." "..request.playerName.." <"..self.names[event.skillKey]..">"
        end
    end
    return table.concat(lines,"\n")
end
function D:Apply(request,result)
    if EC.Features and not EC.Features:DreamLoomEnabled() then return false,"DISABLED" end
    if not self:IsCurrent(request) then return false,"输入已变化，旧结果不能应用，请重新计算。" end
    if not result or not result.verified or (result.status~="SOLVED" and result.status~="BUDGET_LIMIT") then
        return false,"结果尚未通过独立验证，不能应用。"
    end
    -- Revalidate the actual events being written, not just a remembered flag.
    local replay,why=self:Verify(request,result.events)
    if not replay then return false,"验证失败："..tostring(why) end
    local generated=self:TimelineText(request,result,false)
    local base=request.baseText
    -- Keep every original byte and multiplayer assignment; append only new
    -- manual casts. Original S lines already exist, copied spells are not rows.
    local output=base..(base:sub(-1)=="\n" and "" or "\n")..generated
    local plan=EC.RaidaryPlan:GetDB();local _,data=self:GetSettings(plan)
    -- Preserve the currently saved generation before replacing the draft's
    -- provenance, including plans created before the saved-record field existed.
    data.saved=self:FindProvenance(plan,plan.text or "")
    data.baseText=base;data.generatedText=output
    data.generation={rulesVersion=self.rulesVersion,objectiveVersion=self.objectiveVersion,sourceRevision=request.sourceRevision}
    EC.RaidaryPlan:SetDraft(output)
    return true,"已应用到当前方案草稿；请在战术板保存或启用。真实施法回报仍需游戏内验证。"
end
function D:ResultText(request,result)
    if not result.verified then return table.concat(result.diagnostics or {},"\n") end
    local c,l=result.counts,result.losses
    local lines={result.optimal and "模型内最优（1 秒网格）· 独立验证通过" or "已找到可行解 · 独立验证通过；尚未证明最优",
        string.format("球：手动 %d + 复制 %d = %d　绿喷：手动 %d + 复制 %d = %d",c.manualBalls,c.copiedBalls,c.totalBalls,c.manualBreaths,c.copiedBreaths,c.totalBreaths),
        string.format("满充能空转：%d 秒　球减冷却溢出：%d 秒　结束恢复债务：%d 秒",l.fullChargeIdleSeconds,l.cdrOverflowSeconds,result.endingBreathDebt),
        string.format("展开状态：%d　计算 CPU 时间：%.0f ms",result.expandedStates or 0,result.elapsedMs or 0),"","每波安排（开启 / 组合 / 存好 / 释放）"}
    local names={BBY="喷喷球",BYB="喷球喷",BBF="喷喷花"}
    for _,w in ipairs(result.waves) do lines[#lines+1]=self:Clock(w.start).." / "..names[w.pattern].." / "..self:Clock(w.complete).." / "..self:Clock(w.release) end
    lines[#lines+1]="\n技能时间轴（仅真实手动施法；复制仅计数）"
    lines[#lines+1]=self:TimelineText(request,result,true)
    lines[#lines+1]="\n满充能空转区间"
    for _,v in ipairs(l.idleIntervals) do lines[#lines+1]=self:Clock(v.start).."–"..self:Clock(v.finish).."："..(v.finish-v.start).." 秒" end
    lines[#lines+1]="\n球减冷却明细（生效时间 / 来源 / 有效 / 溢出秒数）"
    for _,v in ipairs(l.cdrEvents) do lines[#lines+1]=self:Clock(v.time).." / "..(v.source=="MANUAL" and "手动" or "复制").." / "..v.effective.." / "..v.overflow end
    lines[#lines+1]="\n保留原文（回溯、他人安排和注释；未计算其施法占用）"
    lines[#lines+1]=request.baseText
    return table.concat(lines,"\n")
end
