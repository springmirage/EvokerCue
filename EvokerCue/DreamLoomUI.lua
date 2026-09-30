local _, EC = ...
local D=EC.DreamLoom
local Page={};D.UI=Page
local modeNames={STRICT_BBY="固定喷喷球",FLEX_TOTAL="允许替代组合"}
local function Combat() return (InCombatLockdown and InCombatLockdown()) or (EC.Runtime and EC.Runtime.encounterActive) end
local function NowMs() return debugprofilestop and debugprofilestop() or 0 end
local function Summary(label,text,limit)
    label.fullText=text
    local chars={}
    for char in text:gmatch("[^\128-\191][\128-\191]*") do chars[#chars+1]=char end
    label:SetText(#chars>limit and (table.concat(chars,"",1,limit).."…") or text)
end
local function SummaryTooltip(parent,label)
    label:SetWordWrap(false)
    local hit=CreateFrame("Frame",nil,parent);hit:SetAllPoints(label);hit:EnableMouse(true)
    hit:SetScript("OnEnter",function()
        GameTooltip:SetOwner(hit,"ANCHOR_RIGHT");GameTooltip:SetText(label.fullText or "",nil,nil,nil,nil,true);GameTooltip:Show()
    end)
    hit:SetScript("OnLeave",function() GameTooltip:Hide() end)
end
function Page:SetStatus(text)
    if self.status then self.status:SetText(text or "");self.statusReader:RefreshLayout() end
end
function Page:Invalidate()
    if self.job and not self.job.result then self.job:Cancel() end
    if self.request then
        self.stale=true
        self:SetStatus("输入已变化，计算已取消或结果已失效；请重新计算。")
    end
    if self.apply then self.apply:SetEnabled(false) end
    if self.cancel then self.cancel:SetEnabled(false) end
    if self.start then self.start:SetEnabled(not Combat()) end
end
function Page:Refresh()
    if not self.page then return end
    local plan=EC.RaidaryPlan:GetDB();local settings=D:GetSettings(plan)
    if self.request and not D:IsCurrent(self.request) and not self.stale then self:Invalidate() end
    self.loading=true;self.finish:SetText(settings.endText or "");self.mode:SetText(modeNames[settings.mode] or modeNames.STRICT_BBY);self.loading=false
    Summary(self.plan,"方案："..plan.name,42)
    local catalog=EC.RaidaryPlanUI and EC.RaidaryPlanUI.bossCatalog or EC.RaidaryPlan:GetBossCatalog()
    local entry=EC.RaidaryPlan:FindBoss(plan.boss,catalog)
    Summary(self.boss,"首领："..((not plan.boss or plan.boss=="") and "通用方案" or entry and entry.text or "原绑定未识别"),28)
    local identity=EC:GetPlayerIdentity();local name=identity.candidates and identity.candidates[1] and identity.candidates[1].value or "尚未识别"
    Summary(self.identity,"本人："..name,28)
    -- Inspect only on input changes; switching tabs alone never invalidates jobs.
    local source=EC.RaidaryPlan:GetDraft();local key=D:IdentityKey(identity)
    local aliases=EC.Parser:GetAliasSignature()
    if self.lastDraft~=source or self.lastIdentity~=key or self.lastPlan~=plan.id or self.lastAliases~=aliases then
        self.lastDraft,self.lastIdentity,self.lastPlan,self.lastAliases=source,key,plan.id,aliases
        local base=D:GetBaseForDraft(plan,source)
        local anchors={}
        if type(base)=="string" and #base<=64000 then
            for line in (base.."\n"):gmatch("(.-)\n") do
                local events=EC.Parser:ParseLineEvents(line,0,identity)
                for _,event in ipairs(events or {}) do if event.skillKey=="STASIS" then anchors[#anchors+1]=EC:FormatClock(event.time) end end
            end
        end
        self.anchors:SetText("本人静滞："..(#anchors>0 and table.concat(anchors,"　") or "未识别，请前往战术板填写"))
    end
    self.start:SetEnabled(not Combat() and (not self.job or self.job.result~=nil))
    self.apply:SetEnabled(not Combat() and not self.stale and self.result and self.result.verified==true
        and (self.result.status=="SOLVED" or self.result.status=="BUDGET_LIMIT") or false)
    self.cancel:SetEnabled(self.job~=nil and self.job.result==nil)
end
function Page:Complete(result)
    self.result=result
    if self.stale then return end
    local labels={SOLVED="模型内最优 · 独立验证通过",INFEASIBLE="无解",INVALID_INPUT="输入无效",
        VALIDATION_FAILED="验证失败",BUDGET_LIMIT=result.verified and "已找到可行解 · 预算用尽，尚未证明最优" or "预算用尽，尚未找到可行解",CANCELLED="计算已取消"}
    self:SetStatus(labels[result.status] or result.status)
    self.reader.document:SetText(D:ResultText(self.request,result));self.reader:ScrollToTop()
    self:Refresh()
end
function Page:Start()
    if Combat() then self:SetStatus("请在战斗结束后手动计算；梦境织机不会在战斗中排轴。");return end
    if self.job and not self.job.result then self.job:Cancel() end
    local request,why=D:Prepare()
    self.result=nil;self.request=request;self.stale=false;self.apply:SetEnabled(false)
    if not request then self:SetStatus(why);return end
    self.reader.document:SetText("计算中：正在搜索合法动作和释放时机……");self.reader:ScrollToTop()
    local job=D:NewJob(request);self.job=job;local cpu=0
    self.start:SetEnabled(false);self.cancel:SetEnabled(true)
    local function Tick()
        if self.job~=job or self.stale then return end
        if not D:IsCurrent(request) then self:Invalidate();return end
        if Combat() then job:Cancel();self:Complete(job.result);self:SetStatus("进入战斗，离线计算已取消。");return end
        local begin=NowMs();local result
        for _=1,32 do
            result=job:Step(D.defaults.sliceStates)
            if result or NowMs()-begin>=D.defaults.sliceMs then break end
        end
        cpu=cpu+NowMs()-begin;job.elapsedMs=cpu
        if not result and cpu>=D.defaults.maxCpuMs then result=job:Limit() or job.result end
        if result then result.elapsedMs=cpu;self:Complete(result)
        else
            self:SetStatus(string.format("计算中 · 搜索至 %s / %s · 已展开 %d 状态",D:Clock(job.time),D:Clock(request.fightEnd),job.expandedStates))
            C_Timer.After(0.01,Tick)
        end
    end
    C_Timer.After(0,Tick)
end
function Page:Create(ui,frame)
    local w=ui.widgets
    local page=CreateFrame("Frame",nil,frame);page:SetPoint("TOPLEFT",frame,"TOPLEFT",1,-64);page:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",-1,44);page:Hide()
    self.page=page
    local title=w.CreateText(page,"GameFontNormalLarge","梦境织机",24,-16,850);w.ApplyFont(title,w.style.pageTitle)
    w.CreateText(page,"GameFontHighlightSmall","根据静滞与战斗时长，生成技能时间轴。",24,-44,850)
    self.plan=w.CreateText(page,"GameFontHighlight","",24,-76,650)
    w.CreateButton(page,"前往战术板",734,-68,140,function() ui:ShowTab("plan") end)
    self.boss=w.CreateText(page,"GameFontHighlightSmall","",24,-108,410)
    self.identity=w.CreateText(page,"GameFontHighlightSmall","",454,-108,420)
    SummaryTooltip(page,self.plan);SummaryTooltip(page,self.boss);SummaryTooltip(page,self.identity)
    w.CreateText(page,"GameFontHighlight","战斗结束时间",24,-148,112)
    self.finish=w.CreateEditBox(page,144,-140,112);self.finish:SetMaxLetters(8)
    self.finish:SetScript("OnTextChanged",function(edit,user) if user and not self.loading then D:SetParameter("endText",edit:GetText()) end end)
    w.CreateText(page,"GameFontHighlight","组合模式",288,-148,80)
    self.mode=w.CreateDropdown(page,"EvokerCueDreamLoomMode",376,-140,210,function()
        local settings=D:GetSettings(EC.RaidaryPlan:GetDB())
        return {{text=modeNames.STRICT_BBY,value="STRICT_BBY",selected=settings.mode=="STRICT_BBY"},
            {text=modeNames.FLEX_TOTAL,value="FLEX_TOTAL",selected=settings.mode=="FLEX_TOTAL"}}
    end,function(value) D:SetParameter("mode",value);self:Refresh() end)
    w.CreateButton(page,"模型说明",734,-140,140,function()
        self.explanation:SetShown(not self.explanation:IsShown())
        self.reader:RefreshLayout()
    end)
    self.anchors=w.CreateText(page,"GameFontHighlightSmall","",24,-188,850);self.anchors:SetSpacing(4)
    local fixed=w.CreateText(page,"GameFontHighlightSmall","固定模型：绿喷 1 秒／球 2 秒／花 0 秒；其他技能占用未纳入。",24,-214,850)
    fixed:ClearAllPoints();fixed:SetPoint("TOPLEFT",self.anchors,"BOTTOMLEFT",0,-8)
    self.mapping=w.CreateText(page,"GameFontHighlightSmall","球/花仅视觉提醒（未配置专用语音）；真实施法回报待游戏内验证。",24,0,850)
    self.mapping:ClearAllPoints();self.mapping:SetPoint("TOPLEFT",fixed,"BOTTOMLEFT",0,-6)
    self.reader=w.CreateDocumentReader(page,"EvokerCueDreamLoomResult","填写结束时间，点击“开始计算”。计算和预览不会修改草稿。",24,266,24,86)
    self.reader:ClearAllPoints();self.reader:SetPoint("TOPLEFT",self.mapping,"BOTTOMLEFT",0,-12);self.reader:SetPoint("BOTTOMRIGHT",page,"BOTTOMRIGHT",-24,86)
    -- Details overlay the preview only on explicit request; no permanent lost height.
    self.explanation=CreateFrame("Frame",nil,page,"BackdropTemplate")
    self.explanation:SetPoint("TOPLEFT",self.reader,"TOPLEFT",0,0);self.explanation:SetPoint("TOPRIGHT",self.reader,"TOPRIGHT",0,0);self.explanation:SetHeight(130)
    self.explanation:SetFrameLevel(self.reader:GetFrameLevel()+10);w.SetBackdrop(self.explanation,w.colors.panel,w.colors.border)
    local detail=w.CreateText(self.explanation,"GameFontHighlightSmall",
        "先满足所有硬约束，再依次比较：总球、总喷、喷喷球波数、喷球喷波数、球起手时间总和最小、喷起手时间总和最大、释放时间总和最大。\n固定喷喷球不允许替换；允许替代组合可用喷喷球、喷球喷、喷喷花。\n1 秒网格；静滞间距至少 90 秒；战斗时长上限 30 分钟。结果不等于实际治疗收益最大。",16,-16,818)
    detail:SetSpacing(5);self.explanation:Hide()
    local actions=CreateFrame("Frame",nil,page);actions:SetPoint("BOTTOMLEFT",24,46);actions:SetSize(850,32)
    self.start=w.CreateButton(actions,"开始计算",0,0,120,function() self:Start() end);self.start:SetVariant("primary")
    self.cancel=w.CreateButton(actions,"取消计算",132,0,120,function()
        if self.job and not self.job.result then self.job:Cancel();self:Complete(self.job.result) end
    end)
    self.apply=w.CreateButton(actions,"应用到战术板草稿",264,0,190,function()
        if Combat() then self:SetStatus("请在战斗结束后应用离线结果。");return end
        local ok,message=D:Apply(self.request,self.result)
        self:SetStatus(message)
        if ok then EC.RaidaryPlanUI:LoadSelection();ui:ShowTab("plan") end
    end)
    self.statusReader=w.CreateDocumentReader(page,"EvokerCueDreamLoomStatus","",24,0,24,4)
    self.statusReader:ClearAllPoints();self.statusReader:SetPoint("BOTTOMLEFT",page,"BOTTOMLEFT",24,4);self.statusReader:SetPoint("BOTTOMRIGHT",page,"BOTTOMRIGHT",-24,4);self.statusReader:SetHeight(34)
    self.statusReader:SetBackdrop(nil);self.statusReader.bottomPadding=0
    self.statusReader.scroll:ClearAllPoints();self.statusReader.scroll:SetPoint("TOPLEFT",0,0);self.statusReader.scroll:SetPoint("BOTTOMRIGHT",-24,0)
    self.status=self.statusReader.document;w.ApplyFont(self.status,w.style.caption)
    page:SetScript("OnShow",function() self:Refresh();self.reader:RefreshLayout() end)
    page:SetScript("OnHide",function() self.finish:ClearFocus();self.explanation:Hide() end)
    self:Refresh()
    return page
end
