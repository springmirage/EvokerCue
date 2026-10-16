"""Skill-scoped coverage and known-slot regression; simulated APIs, not game QA."""
from pathlib import Path
import runpy

base = runpy.run_path(str(Path(__file__).with_name('run_audit_fixes.py')))
r = base['r']
r.execute('''
local p,t,c,a=EC.Parser,EC.Timeline,EC.CastTracker,EC.AlertUI
EC.SafeText=function(_,value) return tostring(value) end
local ball='00:10 测试奶龙 球'
local breath='00:00 测试奶龙 静滞\\n00:01 测试奶龙 绿喷'
GetNumGroupMembers=function() return 2 end;IsInRaid=function() return true end
UnitIsUnit=function(unit) return unit=='raid1' end
UnitFullName=function(unit) if unit=='raid2' then return '其他人','测试服' end end
local function parse(text) return p:BuildResult(text,identity) end
local function start(result)
 c:EndSession('fixture');a:ClearEmergency();c:ClearBallCast('fixture')
 now=0;t.active=true;t.startTime=0;t.source='BOSS';t.snapshot=t:BuildSnapshot(result)
 c:BeginSession(t.snapshot,'BOSS',0)
 return t.snapshot
end
local function state(key)
 for _,entry in ipairs(t:GetVisibleEntries(now)) do if entry.event.skillKey==key then return entry.state end end
end
local function knownBall(result, absence)
 assert(result.absenceAllowed.BALL==absence)
 start(result);now=10;t:Update();assert(state('BALL')=='NORMAL')
 now=12;t:Update();assert(state('BALL')=='BALL_LATE')
 c:StartBallCast('late',373861);assert(c.ballCast and c.ballCast.event)
 c:FinishBallCast('other-cast',373861,nil,true);assert(not c.ballCast.event.consumed)
 c:FinishBallCast('late',373861,nil,true);assert(t.snapshot.events[#t.snapshot.events].consumed)
 c:StartBallCast('extra',373861);assert((a.ballEmergencyEntry~=nil)==absence)
 start(result);now=1;c:StartBallCast('early',373861)
 assert((a.ballEmergencyEntry~=nil)==absence)
end
-- CASE 1: Prose is outside the supported arrangement grammar, not an error.
local result=parse(ball..'\\n全团靠左集合，注意躲开地面技能。')
assert(result.integrity.lines[2].status=='COVERED');knownBall(result,true)
-- CASE 2: A suspicious personal ball assignment blocks absence, not known late.
result=parse(ball..'\\n00-20 测试奶龙 球')
assert(result.integrity.domains.BALL.state=='COMPLETE');knownBall(result,true)
-- CASE 3: Unknown payload under a proven other owner is excluded.
result=parse(ball..'\\n00:20 其他人 完全未知技能')
assert(result.integrity.lines[2].segments[1]=='IGNORED');knownBall(result,true)
knownBall(parse(ball..'\\n{time:bad} 其他人 球'),true)
knownBall(parse(ball..'\\n00-20 其他人 球 / 测试奶龙 球'),true)
knownBall(parse(ball..'\\n球'),true)
knownBall(parse(ball..'\\n1. 全团靠左集合。'),true)
-- Unverified owner remains uncertain, but cannot disable reliable slot states.
knownBall(parse(ball..'\\n00:20 未证实角色 球'),true)
-- CASE 4: Breath uncertainty does not suppress ball absence authority.
result=parse(ball..'\\n{time:0:20,p2} 测试奶龙 绿喷')
assert(result.absenceAllowed.DREAM_BREATH==true);knownBall(result,true)
-- CASE 5: Ball uncertainty does not suppress independent Breath quota.
result=parse(breath..'\\n00-20 测试奶龙 球')
assert(result.absenceAllowed.BALL==true and result.absenceAllowed.DREAM_BREATH)
local snapshot=start(result)
c.tracking=true;c.currentWaveIndex=1;c.quotaConfirmed=true;c.currentWaveLimit=1;c.breathCount=1
assert(c:HasReliableQuota() and c:IsOverQuotaBeforeNextBreath())
c:ShowOverQuotaWarning();assert(a.emergencyEntry)
-- CASE 6: Complete ball plan still corrects early and extra casts.
knownBall(parse(ball),true)
-- Known Breath late and START/STOP association work without quota or Stasis.
result=parse('00:10 测试奶龙 绿喷\\n00-20 测试奶龙 绿喷')
snapshot=start(result);now=12;t:Update();assert(state('DREAM_BREATH')=='LATE')
local event=snapshot.events[1]
c:HandleEmpowerStart('breath-a',355936,101)
assert(c.activeEmpower and c.activeEmpower.token==event)
c:HandleEmpowerStop('breath-b',355936,true,nil,101);assert(not event.consumed)
c:HandleEmpowerStop('breath-a',355936,false,nil,101);assert(not event.consumed)
c:HandleEmpowerStart('breath-c',355936,102)
c:HandleEmpowerStop('breath-c',355936,true,nil,102);assert(event.consumed)
assert(not c:HasReliableQuota())
-- Multiple slots use the explicitly requested global ordered ownership.
snapshot=start(parse('00:10 测试奶龙 绿喷\\n00:11 测试奶龙 绿喷'))
now=12;c:HandleEmpowerStart('ambiguous',355936,103)
assert(not c.activeEmpower.knownSlot)
c:HandleEmpowerStop('ambiguous',355936,true,nil,103)
assert(snapshot.events[1].consumed and not snapshot.events[2].consumed)
-- A later, absolutely timed failed Breath assignment affects only that wave.
result=parse(breath..'\\n01:00 测试奶龙 释放静滞\\n01:30 测试奶龙 静滞\\n01:31 测试奶龙 绿喷\\n01:32 测试奶龙 绿喷 待确认')
assert(result.waves[1].quotaReliable and result.waves[2].quotaReliable)
-- Source coverage is still unproven for NSRT/DFT; their parsed slots remain usable.
for _,source in ipairs({'NSRT','DFT'}) do
 result=EC.PlanSources:BuildResult(ball,identity,{source=source,available=true,origins={},issues={}})
 assert(result.integrity.sourceState=='UNKNOWN');knownBall(result,false)
end
-- Changing the live parse cannot change the battle snapshot authority.
result=parse(ball);snapshot=start(result);result.absenceAllowed.BALL=false
assert(snapshot.absenceAllowed.BALL)
''')
print('PASS six requested cases; domain isolation, prose/owner evidence, known Breath success identity, ambiguous ownership, wave locality, NSRT/DFT restrictions, frozen authority')
