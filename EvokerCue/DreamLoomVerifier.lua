local _, EC = ...
local D=EC.DreamLoom
-- Independent verifier: two real charges plus a FIFO recharge queue.
-- It does not call the solver's debt transitions, macros or state encoding.
function D:Verify(request,events)
    local inputError=self:CheckRequest(request)
    if inputError then return nil,inputError end
    local time,charges,queue,ready=0,2,{},9
    local counts={manualBalls=0,copiedBalls=0,manualBreaths=0,copiedBreaths=0}
    local losses={fullChargeIdleSeconds=0,cdrOverflowSeconds=0,idleIntervals={},cdrEvents={}}
    local waves,record,nextAnchor={},nil,1
    local bby,byb,ySum,bSum,rSum=0,0,0,0,0
    local function Advance(target)
        local dt=target-time
        if dt<0 then return false end
        while dt>0 and #queue>0 do
            local used=math.min(dt,queue[1]);queue[1]=queue[1]-used;dt=dt-used;time=time+used
            if queue[1]==0 then table.remove(queue,1);charges=charges+1 end
        end
        if dt>0 then
            losses.fullChargeIdleSeconds=losses.fullChargeIdleSeconds+dt
            local last=losses.idleIntervals[#losses.idleIntervals]
            if last and last.finish==time then last.finish=target else losses.idleIntervals[#losses.idleIntervals+1]={start=time,finish=target} end
        end
        time=target;return true
    end
    local function CDR(source)
        local amount=5
        while amount>0 and #queue>0 do
            local used=math.min(amount,queue[1]);queue[1]=queue[1]-used;amount=amount-used
            if queue[1]==0 then table.remove(queue,1);charges=charges+1 end
        end
        losses.cdrOverflowSeconds=losses.cdrOverflowSeconds+amount
        losses.cdrEvents[#losses.cdrEvents+1]={time=time,source=source,effective=5-amount,overflow=amount}
    end
    local function Fail(index,why) return nil,"事件 "..index.."："..why end
    for index,e in ipairs(events or {}) do
        local key,t=e.skillKey,e.start
        local duration=key=="DREAM_BREATH" and 1 or key=="BALL" and 2 or 0
        if type(t)~="number" or t%1~=0 or t<0 or t+duration>request.fightEnd or e.finish~=t+duration then return Fail(index,"时间或施法时长无效。") end
        if e.kind and e.kind~="MANUAL" then return Fail(index,"复制技能不能作为手动施法行。") end
        if not Advance(t) then return Fail(index,"读条重叠或同秒顺序错误。") end
        if record and record.complete and t>record.complete+30 then return Fail(index,"静滞已过释放截止。") end
        local anchor=request.stasisTimes[nextAnchor]
        if anchor and (t>anchor or (t==anchor and key~="STASIS" and key~="RELEASE_STASIS")) then return Fail(index,"遗漏固定静滞开启。") end
        if key=="STASIS" then
            if record or t~=anchor then return Fail(index,"静滞锚点不符或前包未释放。") end
            record={start=t,skills={},nextTime=t,index=nextAnchor};waves[#waves+1]=record;nextAnchor=nextAnchor+1
        elseif key=="RELEASE_STASIS" then
            if not record or not record.complete or t<record.complete then return Fail(index,"尚未存好静滞。") end
            record.release=t;counts.copiedBreaths=counts.copiedBreaths+2;rSum=rSum+t
            if record.pattern~="BBF" then counts.copiedBalls=counts.copiedBalls+1;CDR("COPIED") end
            record=nil
        elseif key=="DREAM_BREATH" or key=="BALL" or key=="FLOWER" then
            if record and not record.complete and t~=record.nextTime then return Fail(index,"静滞存储中等待或插入技能。") end
            if key=="FLOWER" and (not record or record.complete or #record.skills~=2) then return Fail(index,"花只能作为 BBF 的第三步。") end
            if key=="DREAM_BREATH" then
                if charges<1 then return Fail(index,"绿喷充能不足。") end
                charges=charges-1;queue[#queue+1]=30;counts.manualBreaths=counts.manualBreaths+1;bSum=bSum+t
            elseif key=="BALL" then
                if t<ready then return Fail(index,"球冷却未好。") end
                ready=t+14;counts.manualBalls=counts.manualBalls+1;ySum=ySum+t
            end
            local nextFixed=request.stasisTimes[nextAnchor]
            if nextFixed and t+duration>nextFixed then return Fail(index,"读条跨越固定静滞。") end
            if record and record.complete and t+duration>record.complete+30 then return Fail(index,"读条跨越释放截止。") end
            Advance(t+duration)
            if key=="BALL" then CDR("MANUAL") end
            if record and not record.complete then
                record.skills[#record.skills+1]=key=="DREAM_BREATH" and "B" or key=="BALL" and "Y" or "F"
                record.nextTime=time
                if #record.skills==3 then
                    record.pattern=table.concat(record.skills)
                    if record.pattern~="BBY" and record.pattern~="BYB" and record.pattern~="BBF" then return Fail(index,"存储组合非法。") end
                    if request.mode=="STRICT_BBY" and record.pattern~="BBY" then return Fail(index,"固定喷喷球模式不能替换组合。") end
                    record.complete=time
                    if record.pattern=="BBY" then bby=bby+1 elseif record.pattern=="BYB" then byb=byb+1 end
                end
            end
        else return Fail(index,"固定模型中未知的技能。") end
    end
    if record or nextAnchor<=#request.stasisTimes then return nil,"尚有静滞未完整存储或释放。" end
    Advance(request.fightEnd)
    local debt=0;for _,remaining in ipairs(queue) do debt=debt+remaining end
    counts.totalBalls=counts.manualBalls+counts.copiedBalls
    counts.totalBreaths=counts.manualBreaths+counts.copiedBreaths
    local effective=0;for _,e in ipairs(losses.cdrEvents) do effective=effective+e.effective end
    if counts.manualBreaths*30-(request.fightEnd-losses.fullChargeIdleSeconds)-effective~=debt then return nil,"独立重放的资源守恒失败。" end
    return {counts=counts,waves=waves,losses=losses,endingBreathDebt=debt,
        score={counts.totalBalls,counts.totalBreaths,bby,byb,-ySum,bSum,rSum}}
end
