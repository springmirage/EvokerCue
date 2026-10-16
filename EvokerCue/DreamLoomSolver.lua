local _, EC = ...
local D = EC.DreamLoom
local Job = {}; Job.__index = Job
local max = math.max
local function Key(w,y,p) return (w*15+y)*3+p end
local function Score(s,b,br,bby,byb,ys,bs,rs)
    return {s[1]+b,s[2]+br,s[3]+bby,s[4]+byb,s[5]-ys,s[6]+bs,s[7]+rs}
end
local function Put(dp,t,w,y,p,score,parent,action,at,wave)
    local f=dp[t]
    if not f then f={map={},keys={}};dp[t]=f end
    local k=Key(w,y,p);local old=f.map[k]
    if not old or D:Better(score,old.score) then
        if not old then f.keys[#f.keys+1]=k end
        f.map[k]={w=w,y=y,p=p,score=score,parent=parent,action=action,at=at,wave=wave}
    end
end
local function Record(w,y,pattern)
    local dt=0
    for _,a in ipairs(D.patterns[pattern]) do
        if a=="B" then
            if w>30 then return end
            w=w+30
        elseif a=="Y" then
            if y>0 then return end
            y=14
        end
        local duration=a=="B" and 1 or a=="Y" and 2 or 0
        dt=dt+duration;w=max(0,w-duration);y=max(0,y-duration)
        if a=="Y" then w=max(0,w-5) end
    end
    return w,y,dt
end
-- A recording macro is an exact composition of the three mandatory actions:
-- it removes no waits/choices, since waiting or releasing mid-record is illegal.
function Job:Search()
    local r=self.request;local dp={}
    Put(dp,0,0,9,0,{0,0,0,0,0,0,0})
    local anchorAt,nextAt,prior={}, {}, {}
    for i,t in ipairs(r.stasisTimes) do anchorAt[t]=i end
    local i,previous=1,nil
    for t=0,r.fightEnd do
        prior[t]=previous;nextAt[t]=r.stasisTimes[i]
        if anchorAt[t] then previous=t;i=i+1 end
    end
    for t=0,r.fightEnd do
        self.time=t
        local f=dp[t]
        if f then
            -- Complete release closure BEFORE expanding the layer. New p=0
            -- states participate below, including at the exact fight end.
            local count=#f.keys
            for j=1,count do
                local n=f.map[f.keys[j]]
                if n.p>0 then
                    local deadline=prior[t]+(n.p==1 and 4 or 2)+30
                    if t<=deadline then
                        Put(dp,t,n.p==1 and max(0,n.w-5) or n.w,n.y,0,
                            Score(n.score,n.p==1 and 1 or 0,2,0,0,0,0,t),n,"R",t)
                    end
                end
                coroutine.yield()
            end
            for j=1,#f.keys do
                local n=f.map[f.keys[j]]
                self.expandedStates=self.expandedStates+1
                if t==r.fightEnd then
                    if n.p==0 and (not self.best or D:Better(n.score,self.best.score)) then self.best=n end
                else
                    local deadline=n.p>0 and (prior[t]+(n.p==1 and 4 or 2)+30) or r.fightEnd
                    local wave=anchorAt[t]
                    if wave then
                        if n.p==0 then
                            local patterns=r.mode=="STRICT_BBY" and {"BBY"} or {"BBY","BYB","BBF"}
                            for _,pattern in ipairs(patterns) do
                                local w,y,dt=Record(n.w,n.y,pattern)
                                if w and t+dt<=r.fightEnd and (not r.stasisTimes[wave+1] or t+dt<=r.stasisTimes[wave+1]) then
                                    local ball=pattern~="BBF"
                                    Put(dp,t+dt,w,y,ball and 1 or 2,
                                        Score(n.score,ball and 1 or 0,2,pattern=="BBY" and 1 or 0,pattern=="BYB" and 1 or 0,
                                            ball and (t+(pattern=="BBY" and 2 or 1)) or 0,2*t+(pattern=="BYB" and 3 or 1),0),
                                        n,pattern,t,wave)
                                end
                            end
                        end
                    else
                        local limit=math.min(r.fightEnd,deadline,nextAt[t] or r.fightEnd)
                        if t+1<=limit then
                            -- Stable tie order: wait, breath, ball. No cross-state
                            -- resource dominance or full-charge greedy pruning.
                            Put(dp,t+1,max(0,n.w-1),max(0,n.y-1),n.p,n.score,n,"W",t)
                            if n.w<=30 then
                                Put(dp,t+1,n.w+29,max(0,n.y-1),n.p,Score(n.score,0,1,0,0,0,t,0),n,"B",t)
                            end
                        end
                        if n.y==0 and t+2<=limit then
                            Put(dp,t+2,max(0,n.w-7),12,n.p,Score(n.score,1,0,0,0,t,0,0),n,"Y",t)
                        end
                    end
                end
                coroutine.yield()
            end
            dp[t]=nil -- parent references retain only paths still in contention
        end
    end
end
function Job:Finish(status)
    if self.result then return self.result end
    local r=self.request
    local result={status=status,optimal=status=="SOLVED",verified=false,events={},diagnostics={},
        rulesVersion=D.rulesVersion,objectiveVersion=D.objectiveVersion,expandedStates=self.expandedStates,
        elapsedMs=self.elapsedMs or 0,sourceRevision=r.sourceRevision}
    if self.best then
        local path,n={},self.best
        while n and n.action do path[#path+1]=n;n=n.parent end
        local function Add(a,t,wave)
            result.events[#result.events+1]={start=t,finish=t+(a=="B" and 1 or a=="Y" and 2 or 0),
                order=#result.events+1,skillKey=D.keys[a],kind="MANUAL",wave=wave,generated=true}
        end
        for j=#path,1,-1 do
            local n=path[j];local a=n.action
            if D.patterns[a] then
                Add("S",n.at,n.wave);local t=n.at
                for _,skill in ipairs(D.patterns[a]) do Add(skill,t,n.wave);t=t+(skill=="B" and 1 or skill=="Y" and 2 or 0) end
            elseif a~="W" then Add(a,n.at) end
        end
        local verified,why=D:Verify(r,result.events)
        if verified then
            for k,v in pairs(verified) do result[k]=v end
            for j=1,7 do if result.score[j]~=self.best.score[j] then why="求解目标与独立重放不一致。" end end
        end
        if why then result.status="VALIDATION_FAILED";result.optimal=false;result.verified=false;result.diagnostics={why}
        else result.verified=true end
    elseif status=="SOLVED" then
        result.status="INFEASIBLE";result.optimal=false
        local wave=1;for i,t in ipairs(r.stasisTimes) do if t<=self.time then wave=i end end
        result.diagnostics={"无满足固定锚点与释放约束的路径；请检查第 "..wave.." 波及其球/喷资源、战斗结束时间。"}
    end
    self.result=result;self.thread=nil;self.best=nil
    return result
end
function Job:Cancel() if not self.result then self:Finish("CANCELLED") end end
function Job:Limit() if not self.result then self:Finish("BUDGET_LIMIT") end end
function Job:Step(budget)
    if EC.Features and not EC.Features:DreamLoomEnabled() then
        self.best=nil;self.thread=nil
        self.result={status="DISABLED",optimal=false,verified=false,events={},diagnostics={}}
        return self.result
    end
    if self.result then return self.result end
    for _=1,(budget or 64) do
        if self.expandedStates>=self.maxStates then return self:Finish("BUDGET_LIMIT") end
        local ok,why=coroutine.resume(self.thread)
        if not ok then
            self.best=nil;local result=self:Finish("VALIDATION_FAILED");result.diagnostics={tostring(why)};return result
        end
        if coroutine.status(self.thread)=="dead" then return self:Finish("SOLVED") end
    end
end
function D:NewJob(request,options)
    if EC.Features and not EC.Features:DreamLoomEnabled() then
        return setmetatable({expandedStates=0, result={status="DISABLED",optimal=false,verified=false,events={},diagnostics={}}},Job)
    end
    -- Snapshot all solver inputs; caller mutation cannot change a live search.
    if type(request) ~= "table" then request = {} end
    local r={fightEnd=request.fightEnd,mode=request.mode,stasisTimes={},sourceRevision=request.sourceRevision}
    local errorText=self:CheckRequest(request)
    if type(request.stasisTimes) == "table" then
        for i,t in ipairs(request.stasisTimes) do r.stasisTimes[i]=t end
    end
    local job=setmetatable({request=r,expandedStates=0,time=0,maxStates=options and options.maxStates or self.defaults.maxStates},Job)
    if errorText then job.result={status="INVALID_INPUT",optimal=false,verified=false,diagnostics={errorText},events={}};return job end
    job.thread=coroutine.create(function() job:Search() end)
    return job
end
function D:Solve(request,options)
    local job=self:NewJob(request,options)
    while not job.result do job:Step(10000) end
    return job.result
end
