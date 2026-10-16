from pathlib import Path
from lupa.lua51 import LuaRuntime
import json
ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'

def runtime(mock=False, modules=()):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute((TESTS/'wow_mock.lua').read_text(encoding='utf-8-sig') if mock else 'EC={}')
    # This legacy isolated harness omits Core.lua. Use its real shared ID reader,
    # rather than copying an implementation into the mock.
    core = (ROOT/'Core.lua').read_text(encoding='utf-8-sig')
    first = core.index('function EC:ReadCastBarID(')
    last = core.index('\nfunction ', first + 1)
    lua.execute(core[first:last])
    for name in modules:
        lua.execute((ROOT/name).read_text(encoding='utf-8-sig'), 'EvokerCue', lua.globals().EC)
    return lua

MODEL = ['DreamLoom.lua','DreamLoomVerifier.lua','DreamLoomSolver.lua']
r = runtime(modules=MODEL)
for path in ROOT.glob('*.lua'):
    r.execute('assert(loadstring(...))', path.read_text(encoding='utf-8-sig'))
print('PASS Lua 5.1 syntax: all top-level addon files')
r.execute('''
local d=EC.DreamLoom
for _,mode in ipairs({'STRICT_BBY','FLEX_TOTAL'}) do
 local r=d:Solve({fightEnd=392,mode=mode,stasisTimes={36,130,225,317}})
 assert(r.status=='SOLVED' and r.verified and r.optimal)
 assert(r.counts.totalBalls==30 and r.counts.manualBreaths==18 and r.counts.totalBreaths==26)
 assert(#r.waves==4)
 for _,w in ipairs(r.waves) do assert(w.pattern=='BBY') end
 local r2=d:Solve({fightEnd=392,mode=mode,stasisTimes={36,130,225,317}})
 for i,e in ipairs(r.events) do assert(e.skillKey==r2.events[i].skillKey and e.start==r2.events[i].start) end
end
local input={fightEnd=40,mode='STRICT_BBY',stasisTimes={36}}
local r=d:Solve(input);assert(r.verified and r.waves[1].release==40) -- R exactly at T
local bad={};for i,e in ipairs(r.events) do bad[i]={};for k,v in pairs(e) do bad[i][k]=v end end
bad[#bad].start=41;bad[#bad].finish=41;assert(not d:Verify(input,bad))
bad[1].kind='COPIED';assert(not d:Verify(input,bad))
assert(d:Solve({fightEnd=3,mode='STRICT_BBY',stasisTimes={0}}).status=='INFEASIBLE')
local flower=d:Solve({fightEnd=2,mode='FLEX_TOTAL',stasisTimes={0}})
assert(flower.verified and flower.waves[1].pattern=='BBF' and flower.counts.totalBalls==0)
for _,badInput in ipairs({{}, {fightEnd=40,mode='bad',stasisTimes={}}, {fightEnd=40,mode='FLEX_TOTAL',stasisTimes={1,1}},
 {fightEnd=400,mode='FLEX_TOTAL',stasisTimes={1,80}}, {fightEnd=400,mode='FLEX_TOTAL',stasisTimes={1.5}}}) do
 assert(d:Solve(badInput).status=='INVALID_INPUT')
end
assert(d:Solve(nil).status=='INVALID_INPUT')
local job=d:NewJob(input);assert(not job:Step(1));job:Cancel();assert(job.result.status=='CANCELLED' and not job.result.optimal)
local cap=d:Solve(input,{maxStates=1});assert(cap.status=='BUDGET_LIMIT' and not cap.optimal)
-- Stop after a feasible terminal state is found, before exhaustive proof.
job=d:NewJob(input)
while not job.best and not job.result do job:Step(1) end
assert(job.best and not job.result);job:Limit()
assert(job.result.verified and job.result.status=='BUDGET_LIMIT' and not job.result.optimal)
-- Input snapshot does not follow caller mutation.
job=d:NewJob(input);input.stasisTimes[1]=0
while not job.result do job:Step(10) end
assert(job.result.verified and job.result.waves[1].start==36)
''')
print('PASS model optimum, deterministic ties, boundaries, BBF fallback, invalid input, cancellation, feasible/infeasible budgets, snapshot')
fixture=json.loads((TESTS/'dreamloom_historical.json').read_text())
events=[]
for e in fixture['events']:
    if e['t'] in [36,130,225,317] and e['act']=='B':
        events.append({'start':e['t'],'finish':e['t'],'skillKey':'STASIS','kind':'MANUAL'})
    events.append({'start':e['t'],'finish':e['end'],'skillKey':{'B':'DREAM_BREATH','Y':'BALL','R':'RELEASE_STASIS'}[e['act']],'kind':'MANUAL'})
def convert(lua, value):
    if isinstance(value,dict): return lua.table_from({k:convert(lua,v) for k,v in value.items()})
    if isinstance(value,list): return lua.table_from([convert(lua,v) for v in value])
    return value
r.globals().historical=convert(r,events)
r.execute('''
local v=assert(EC.DreamLoom:Verify({fightEnd=392,mode='STRICT_BBY',stasisTimes={36,130,225,317}},historical))
assert(v.losses.fullChargeIdleSeconds==46 and v.losses.cdrOverflowSeconds==15 and v.endingBreathDebt==59)
''')
print('PASS historical independent replay: idle 46 / overflow 15 / ending debt 59')

# Exhaustive short-horizon oracle: enumerates primitive casts and all legal
# waits/releases, uses actual charge FIFO, no macro or solver state encoding.
def oracle(T, anchor, mode):
    best=None
    def advance(q,n):
        q=list(q)
        while n and q:
            take=min(n,q[0]);n-=take;q[0]-=take
            if q[0]==0:q.pop(0)
        return tuple(q)
    def visit(t,q,ready,phase,combo,complete,score):
        nonlocal best
        if phase==2 and t>complete+30:return
        if t==T:
            if phase==3 and (best is None or score>best):best=score
        if phase==0 and t==anchor:
            visit(t,q,ready,1,'',None,score);return
        if phase==2:
            ns=list(score);ns[0]+=int(combo!='BBF');ns[1]+=2;ns[6]+=t
            visit(t,advance(q,5) if combo!='BBF' else q,ready,3,combo,complete,tuple(ns))
        if t==T and phase!=1:return
        limit=min(T, anchor if phase==0 else T, complete+30 if phase==2 else T)
        if phase!=1 and t+1<=limit:visit(t+1,advance(q,1),ready,phase,combo,complete,score)
        for a,duration in [('B',1),('Y',2),('F',0)]:
            if t+duration>limit:continue
            if a=='B' and len(q)>=2:continue
            if a=='Y' and t<ready:continue
            if a=='F' and not(phase==1 and combo=='BB' and mode=='FLEX_TOTAL'):continue
            c=combo+a if phase==1 else combo
            patterns=['BBY'] if mode=='STRICT_BBY' else ['BBY','BYB','BBF']
            if phase==1 and not any(p.startswith(c) for p in patterns):continue
            ns=list(score);ns[0]+=int(a=='Y');ns[1]+=int(a=='B');ns[4]-=t if a=='Y' else 0;ns[5]+=t if a=='B' else 0
            nq=advance(q+(30,) if a=='B' else q,duration)
            if a=='Y':nq=advance(nq,5)
            p=phase;done=complete
            if phase==1 and len(c)==3:
                p=2;done=t+duration;ns[2]+=int(c=='BBY');ns[3]+=int(c=='BYB')
            visit(t+duration,nq,t+14 if a=='Y' else ready,p,c,done,tuple(ns))
    visit(0,(),9,0,'',None,(0,)*7)
    return best
for T in [2,4,8,11,14,16]:
    for anchor in [0,max(0,T-4)]:
        for mode in ['STRICT_BBY','FLEX_TOTAL']:
            expected=oracle(T,anchor,mode)
            result=r.execute('return EC.DreamLoom:Solve({fightEnd=...,mode=select(2,...),stasisTimes={select(3,...)}})',T,mode,anchor)
            actual=tuple(result['score'][i] for i in range(1,8)) if result['verified'] else None
            assert actual==expected,(T,anchor,mode,actual,expected)
print('PASS 24 small-horizon exhaustive primitive-action oracle comparisons')

# UI/API integration is simulated and does not validate game rendering.
u=runtime(True, ['Parser.lua','RaidaryPlan.lua']+MODEL+['DreamLoomFormatter.lua','UI.lua','RaidaryPlanUI.lua','DreamLoomUI.lua'])
u.execute('''
timers={};C_Timer.After=function(_,callback) timers[#timers+1]=callback end
function pump(limit)
 local n=0
 while #timers>0 do n=n+1;assert(n<(limit or 10000),'timer did not terminate');table.remove(timers,1)() end
 return n
end
local ui=EC.UI
ui.frame=CreateFrame('Frame');ui.functionRoot=CreateFrame('Frame')
ui:CreateOverviewPage(ui.frame)
ui.Refresh=function(self) self:RefreshOverview();EC.DreamLoom.UI:Refresh() end
ui.planPage=EC.RaidaryPlanUI:Create(ui,ui.frame)
ui.loomPage=EC.DreamLoom.UI:Create(ui,ui.frame)
ui:CreateBottomTabs(ui.frame)
local d,p,plan=EC.DreamLoom,EC.RaidaryPlanUI,EC.RaidaryPlan
assert(ui.tabButtons.functions.label:GetText()=='设置' and ui.tabButtons.loom.label:GetText()=='梦境织机' and ui.tabButtons.plan.label:GetText()=='战术板')
local source='# 原注释\\n00:36 测试奶龙 静滞 / 其他人 回溯\\n00:12 测试奶龙 回溯'
p.editor:SetText(source);p.editor:fire('OnTextChanged',true)
d:SetParameter('endText','00:50')
local saved=plan:GetText();local selectedSource=EC.PlanSources:GetSelected();local planID=plan:GetDB().id
local rev=d.inputRevision;local request=assert(d:Prepare());assert(request.baseText==source and request.stasisTimes[1]==36)
local frameCount=#frames
for i=1,3 do ui:ShowTab('loom');ui:ShowTab('plan');ui:ShowTab('functions') end
assert(d.inputRevision==rev and plan:GetDraft()==source and #frames==frameCount)
d.UI:Start();assert(d.UI.job and not d.UI.job.result and #timers>0)
ui:ShowTab('plan');ui:ShowTab('loom');assert(not d.UI.stale)
assert(pump()>1 and d.UI.result.verified and d.UI.result.optimal)
assert(plan:GetText()==saved and plan:GetDraft()==source and EC.PlanSources:GetSelected()==selectedSource)
click('应用到战术板草稿');local output=plan:GetDraft()
assert(ui.activeTab=='plan' and output:sub(1,#source)==source and plan:GetText()==saved)
assert(p.editor:GetText()==output and EC.PlanSources:GetSelected()==selectedSource)
local r2=assert(d:Prepare());local solved=d:Solve(r2);assert(d:Apply(r2,solved));assert(plan:GetDraft()==output)
-- Exact provenance supports regeneration, edited manual generated rows cannot be removed.
plan:SetDraft(output..'\\n# edited');assert(not d:Prepare())
plan:SetDraft(source..'\\n# new clean input');assert(d:Prepare())
-- Restoring the source allows fresh solving; old results cannot cross a plan/param/draft change.
plan:SetDraft(source);local req=assert(d:Prepare());local res=d:Solve(req)
d:SetParameter('endText','00:51');assert(not d:Apply(req,res))
d:SetParameter('endText','00:50');req=assert(d:Prepare());res=d:Solve(req)
plan:Create();assert(not d:Apply(req,res));plan:Select(planID);p:LoadSelection()
req=assert(d:Prepare());res=d:Solve(req);plan:SetDraft(source..'\\n');assert(not d:Apply(req,res))
plan:SetDraft(source);d.UI:Start();local job=d.UI.job;d:SetParameter('endText','00:52');pump()
assert(job.result.status=='CANCELLED' and d.UI.stale and not d.UI.apply:IsEnabled())
d.UI:Start();InCombatLockdown=function() return true end;pump();assert(d.UI.result.status=='CANCELLED')
d.UI:Start();assert(d.UI.status:GetText():find('战斗结束',1,true));InCombatLockdown=function() return false end
-- Apply/save uses the existing controls, does not enable or bind implicitly.
d.UI:Start();pump();click('应用到战术板草稿');click('保存')
assert(plan:GetText()==plan:GetDraft());local last=plan:GetDraft()
ui:ShowTab('functions');ui:ShowTab('loom');ui:ShowTab('plan');assert(p.editor:GetText()==last)
for _,button in ipairs(p.actionButtons) do assert(button:IsShown() and button:GetParent()==p.actionBar) end
-- One wheel callback, consistent logical movement and clamp at either end.
for _,scroll in ipairs({ui.overviewScroll,p.editorScroll,p.previewScroll,d.UI.reader.scroll,d.UI.statusReader.scroll}) do
 for _,scale in ipairs({0.7,1,1.5}) do
  ui.frame:SetScale(scale);scroll.range=1000;scroll.offset=100;scroll:fire('OnMouseWheel',-1);assert(scroll.offset==144)
  scroll:fire('OnMouseWheel',100);assert(scroll.offset==0);scroll:fire('OnMouseWheel',-100);assert(scroll.offset==1000)
 end
end
-- The parser sees the user's confirmed spell IDs and generated aliases.
for _,text in ipairs({'球','溜溜球','时空畸体','{spell:373861}'}) do
 local events=EC.Parser:ParseLineEvents('00:20 测试奶龙 '..text,1,identity);assert(#events==1 and events[1].skillKey=='BALL')
end
for _,text in ipairs({'花','{spell:355913}'}) do
 local events=EC.Parser:ParseLineEvents('00:20 测试奶龙 '..text,1,identity);assert(#events==1 and events[1].skillKey=='FLOWER')
end
''')
print('PASS mocked UI: three tabs, draft/provenance preservation, async slices, cancel/combat guard, stale-result rejection, save flow, action buttons, scroll steps, spell mapping')
c=runtime(True,['Parser.lua','CastTracker.lua','Timeline.lua'])
c.execute('''
now=0;GetTime=function() return now end
local secret={}
EC.IsSecret=function(_,v) return v==secret end
EC.Log=function() end
EC.CanShowGameplay=function() return true end
EC.db.enabled=true;EC.db.reminder={enabled=true,leadTime=3,postHold=0.9}
local t,c=EC.Timeline,EC.CastTracker
local function setup()
 now=10;c:ClearBallCast('fixture');local e={slotReliable=true,skillKey='BALL',time=10,eventID=1}
 local later={slotReliable=true,skillKey='BALL',time=14,eventID=2}
 t.snapshot={absenceAllowed={BALL=true},negativeCorrectionAllowed=true,events={e,later},waves={},lastEventTime=14};t.startTime=0;t.active=true;t.source='COMBAT'
 c.snapshot=t.snapshot;c.sessionActive=true
 return e,later
end
c:Initialize()
local function send(event,guid,spell,bar) c.eventFrame:fire('OnEvent',event,'player',guid,spell or 373861,bar) end
local e,later=setup()
send('UNIT_SPELLCAST_START','cast-1');assert(e.manualCastPending and not e.consumed)
now=11.2;t:Update();assert(not e.expired and #t:GetVisibleEntries(now)>=1)
send('UNIT_SPELLCAST_SUCCEEDED','copied-1');assert(not e.consumed and e.manualCastPending)
send('UNIT_SPELLCAST_STOP','cast-1');assert(e.manualCastPending) -- not treated as success/failure
now=12.2;send('UNIT_SPELLCAST_SUCCEEDED','cast-1')
assert(e.consumed and e.dismissed and not later.consumed and not c.ballCast)
send('UNIT_SPELLCAST_SUCCEEDED','cast-1');assert(not later.consumed)
e=setup();send('UNIT_SPELLCAST_START','interrupted');now=11.5;send('UNIT_SPELLCAST_INTERRUPTED','interrupted');t:Update()
assert(not e.consumed and e.expired and not c.ballCast)
e=setup();send('UNIT_SPELLCAST_START','failed');send('UNIT_SPELLCAST_FAILED','wrong');assert(c.ballCast)
send('UNIT_SPELLCAST_FAILED','failed');assert(not c.ballCast and not e.consumed)
send('UNIT_SPELLCAST_START','retry');now=12;send('UNIT_SPELLCAST_SUCCEEDED','failed');assert(not e.consumed)
send('UNIT_SPELLCAST_SUCCEEDED','retry');assert(e.consumed)
e=setup();send('UNIT_SPELLCAST_SUCCEEDED','no-start');assert(not e.consumed)
send('UNIT_SPELLCAST_START',nil);assert(not c.ballCast)
send('UNIT_SPELLCAST_START',secret);assert(not c.ballCast)
send('UNIT_SPELLCAST_START','known',373861,101)
send('UNIT_SPELLCAST_SUCCEEDED','known',373861,102);assert(not e.consumed) -- conflict wins
send('UNIT_SPELLCAST_SUCCEEDED','known',373861,101);assert(e.consumed)
e=setup();send('UNIT_SPELLCAST_START',nil,373861,102);now=12;send('UNIT_SPELLCAST_SUCCEEDED',nil,373861,102);assert(e.consumed)
e=setup();send('UNIT_SPELLCAST_START','timeout');now=26;t:Update();assert(e.expired and not e.consumed and not c.ballCast)
e=setup();send('UNIT_SPELLCAST_START','old-session');t:Stop('test',true)
assert(not e.manualCastPending and not c.ballCast);e=setup();send('UNIT_SPELLCAST_SUCCEEDED','old-session');assert(not e.consumed)
send('UNIT_SPELLCAST_START','dead');c.eventFrame:fire('OnEvent','PLAYER_DEAD');assert(not c.ballCast and not e.consumed)
-- A test timeline ending at the ball must not stop before its real cast completes.
e=setup();t.source='MRT_TEST';t.snapshot.events={e};t.snapshot.lastEventTime=10
send('UNIT_SPELLCAST_START','last-ball');now=11.5;t:Update();assert(t.active and not e.expired)
now=12;send('UNIT_SPELLCAST_SUCCEEDED','last-ball');t:Update();assert(e.consumed and not t.active)
''')
print('PASS real runtime handlers with mocked events: 0.9s hold / 2s cast, exact success identity, copied/unpaired success, STOP, failure/interruption/retry, secret/absent/conflicting IDs, timeout/death/session reset, last test event')

r.execute('''
local d=EC.DreamLoom
local function e(key,t,len) return {skillKey=key,start=t,finish=t+len,kind='MANUAL'} end
-- BYB can legally recover the second charge where immediate BBY cannot.
local events={e('DREAM_BREATH',0,1),e('STASIS',26,0),e('DREAM_BREATH',26,1),e('BALL',27,2),e('DREAM_BREATH',29,1),e('RELEASE_STASIS',30,0)}
local req={fightEnd=30,mode='FLEX_TOTAL',stasisTimes={26}}
local v=assert(d:Verify(req,events));assert(v.waves[1].pattern=='BYB')
req.mode='STRICT_BBY';assert(not d:Verify(req,events))
-- Five seconds crosses from the first recharge to the next, not truncated at one layer.
v=assert(d:Verify({fightEnd=27,mode='FLEX_TOTAL',stasisTimes={}}, {e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('BALL',25,2)}))
assert(v.endingBreathDebt==28 and v.losses.cdrOverflowSeconds==0)
assert(not d:Verify({fightEnd=12,mode='FLEX_TOTAL',stasisTimes={}}, {e('BALL',8,2)}))
''')
print('PASS independent verifier BYB charge recovery, strict rejection, cross-layer CDR, initial ball cooldown')
r.execute('''
local d=EC.DreamLoom
local function e(k,t,n) return {skillKey=k,start=t,finish=t+n,kind='MANUAL'} end
local function verify(T,events,S,mode) return d:Verify({fightEnd=T,mode=mode or 'FLEX_TOTAL',stasisTimes=S or {}},events) end
-- Sequential two-charge recovery: the third B at debt 31 fails; debt 30 succeeds.
assert(not verify(31,{e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('DREAM_BREATH',29,1)}))
assert(verify(31,{e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('DREAM_BREATH',30,1)}))
assert(not verify(32,{e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('DREAM_BREATH',30,1),e('DREAM_BREATH',31,1)}))
assert(verify(62,{e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('DREAM_BREATH',60,1),e('DREAM_BREATH',61,1)}))
local v=assert(verify(28,{e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('BALL',26,2)}))
assert(v.endingBreathDebt==27 and v.losses.cdrOverflowSeconds==0)
v=assert(verify(27,{e('DREAM_BREATH',0,1),e('BALL',25,2)}))
assert(v.endingBreathDebt==0 and v.losses.cdrOverflowSeconds==2)
assert(verify(25,{e('BALL',9,2),e('BALL',23,2)}))
assert(not verify(25,{e('BALL',9,2),e('BALL',22,2)}))
local bby={e('DREAM_BREATH',0,1),e('STASIS',29,0),e('DREAM_BREATH',29,1),e('DREAM_BREATH',30,1),e('BALL',31,2),e('RELEASE_STASIS',33,0)}
assert(verify(33,bby,{29},'STRICT_BBY'))
bby[2]=e('STASIS',28,0);bby[3]=e('DREAM_BREATH',28,1);bby[4]=e('DREAM_BREATH',29,1)
assert(not verify(33,bby,{28},'STRICT_BBY'))
local byb={e('DREAM_BREATH',0,1),e('STASIS',22,0),e('DREAM_BREATH',22,1),e('BALL',23,2),e('DREAM_BREATH',25,1),e('RELEASE_STASIS',26,0)}
assert(verify(26,byb,{22}))
local bbf={e('STASIS',0,0),e('DREAM_BREATH',0,1),e('DREAM_BREATH',1,1),e('FLOWER',2,0),e('RELEASE_STASIS',32,0)}
v=assert(verify(32,bbf,{0}));assert(#v.losses.cdrEvents==0 and v.counts.copiedBalls==0)
bbf[5]=e('RELEASE_STASIS',33,0);assert(not verify(33,bbf,{0}))
assert(verify(392,{e('DREAM_BREATH',391,1)}));assert(not verify(392,{e('DREAM_BREATH',392,1)}))
assert(verify(392,{e('BALL',390,2)}));assert(not verify(392,{e('BALL',391,2)}))
''')
u.execute('''
for _,text in ipairs({'火球术','花开富贵','未知技能'}) do
 local events=EC.Parser:ParseLineEvents('00:20 测试奶龙 '..text,1,identity);assert(not events or #events==0)
end
local events=EC.Parser:ParseLineEvents('00:20 其他人 溜溜球',1,identity);assert(not events or #events==0)
local d,plan=EC.DreamLoom,EC.RaidaryPlan
for _,text in ipairs({'00:36 测试奶龙 <静滞>','{time:0:36} - 测试奶龙 {spell:370537}',
 '{time:0:36} - 测试奶龙 {spellid:370537}','00:36 测试奶龙 |Hspell:370537|h[静滞]|h'}) do
 plan:SetDraft(text);assert(d:Prepare())
end
''')
print('PASS required resource boundaries, BBY debt 1/2, BYB debt 8, BBF deadline, exact fight-end casts, token-only shorthand and supported input formats')
# Integration through the unchanged parser/guard/snapshot path.
u.execute('GetTime=function() return 0 end')
for name in ['PlanGuard.lua','Timeline.lua']:
 u.execute((ROOT/name).read_text(encoding='utf-8-sig'),'EvokerCue',u.globals().EC)
u.execute('''
local d,plan=EC.DreamLoom,EC.RaidaryPlan
for _,case in ipairs({{time='00:00',finish='00:02',mode='FLEX_TOTAL',pattern='BBF'},
 {time='00:36',finish='00:50',mode='STRICT_BBY',pattern='BBY'}}) do
 plan:SetDraft(case.time..' 测试奶龙 静滞');d:SetParameter('endText',case.finish);d:SetParameter('mode',case.mode)
 local req=assert(d:Prepare());local result=d:Solve(req);assert(result.waves[1].pattern==case.pattern)
 assert(d:Apply(req,result));local parsed=plan:Preview();assert(parsed.ok and #parsed.planIssues==0)
 local sIndex
 for i,event in ipairs(parsed.events) do
  if event.skillKey=='STASIS' then sIndex=i end
  if event.skillKey=='DREAM_BREATH' and event.time==req.stasisTimes[1] then assert(sIndex and sIndex<i) end
 end
 local snapshot=EC.Timeline:BuildSnapshot(parsed);local count=#snapshot.events
 plan:SetDraft('00:10 测试奶龙 回溯');plan:Save()
 assert(#snapshot.events==count and snapshot.events[1].skillKey~='REWIND')
end
''')
print('PASS generated BBY/BBF through Parser, PlanGuard and immutable battle snapshot; same-second S precedes B')

v=runtime(True,['Parser.lua','RaidaryPlan.lua']+MODEL+['DreamLoomFormatter.lua','UI.lua','RaidaryPlanUI.lua','DreamLoomUI.lua'])
v.execute('''
EC.UI:CreatePanel()
local ui=EC.UI
assert(ui.frame:GetWidth()==900 and ui.frame:GetHeight()==760)
local count=#frames
for i=1,5 do
 ui:ShowTab('loom');ui:ShowTab('plan');ui:ShowTab('functions')
 for _,key in ipairs({'overview','timeline','reminder','interface','sound','feedback'}) do ui:ShowPage(key) end
end
assert(#frames==count)
assert(ui.aliasEdits.BALL and ui.aliasEdits.FLOWER)
for _,size in ipairs({{1024,768},{1920,1080},{3840,2160}}) do
 UIParent:SetSize(unpack(size));ui:FitPanelToScreen()
end
''')
print('PASS complete panel construction and repeated six settings pages / three primary tabs without frame growth; fit-to-screen executes at three sizes (not visual validation)')
# Long metadata stays a compact summary with a full-text tooltip, and alias
# changes invalidate interpretation even when the source bytes are unchanged.
v.execute('''
local d,plan=EC.DreamLoom,EC.RaidaryPlan
plan:GetDB().name=string.rep('超长方案名称',40)
identity.candidates[1].value=string.rep('角色名',15)..'-服务器'
d.UI:Refresh();assert(d.UI.plan.fullText=='方案：'..plan:GetDB().name)
assert(#d.UI.plan:GetText()<#d.UI.plan.fullText and #d.UI.identity:GetText()<#d.UI.identity.fullText)
identity.candidates[1].value='测试奶龙-测试服务器'
plan:SetDraft('00:36 测试奶龙 静滞');d:SetParameter('endText','00:50')
local req=assert(d:Prepare());local result=d:Solve(req)
EC.db.timeline.customAliases.STASIS='自定义静滞';assert(not d:Apply(req,result))
''')
print('PASS long name/identity summary retains full text, parser-alias changes reject stale results')
# Ball correction follows the board only; it never uses or modifies breath quota.
c.execute((ROOT/'AlertUI.lua').read_text(encoding='utf-8-sig'),'EvokerCue',c.globals().EC)
c.execute('''
local t,c,a=EC.Timeline,EC.CastTracker,EC.AlertUI
a.initialized=true;a.frame=CreateFrame('Frame');a.rows={}
EC.db.reminder.locked=true
local function setup()
 c:ClearBallCast('fixture');a:ClearEmergency();now=7
 local e={slotReliable=true,skillKey='BALL',skillName='溜溜球',time=10,eventID=1}
 local next={slotReliable=true,skillKey='BALL',skillName='溜溜球',time=30,eventID=2}
 t.snapshot={absenceAllowed={BALL=true},negativeCorrectionAllowed=true,events={e,next},waves={},lastEventTime=30};t.startTime=0;t.active=true;t.source='COMBAT'
 c.snapshot=t.snapshot;c.sessionActive=true
 return e,next
end
local function send(event,guid) c.eventFrame:fire('OnEvent',event,'player',guid,373861) end
EC.Voice={CancelOwner=function() end,Prune=function() end,Stop=function() end,
 PlaySkill=function(_,key) assert(key~='BALL','ball speech is disabled') end,
 PlaySpecial=function() error('ball must not use breath speech') end}
local e,next=setup();local quota=c.breathCount
now=10;t:Update();assert(a.rows[1].skill:GetText()=='溜溜球' and a.rows[1].quota:GetText()=='')
now=11;t:Update();assert(not e.expired and a.rows[1].countdown:GetText()=='溜溜球晚了')
now=20;t:Update();assert(not e.expired and t:GetVisibleEntries(now)[1].state=='BALL_LATE')
send('UNIT_SPELLCAST_START','late');assert(c.ballCast.event==e)
now=22;send('UNIT_SPELLCAST_SUCCEEDED','late');assert(e.consumed and not next.consumed)
assert(c.breathCount==quota)
-- A valid two-second cast is not called late just because postHold is 0.9.
e=setup();now=10;send('UNIT_SPELLCAST_START','ontime');now=11.2;t:Update()
assert(a.rows[1].countdown:GetText()=='施法中')
now=13;t:Update();assert(a.rows[1].countdown:GetText()=='施法中')
send('UNIT_SPELLCAST_INTERRUPTED','ontime');assert(not e.consumed and not e.expired)
send('UNIT_SPELLCAST_START','retry');now=15;send('UNIT_SPELLCAST_SUCCEEDED','retry');assert(e.consumed)
-- Too early: immediate cancel text, correct ball icon/name, no quota or sounds.
e=setup();now=2;send('UNIT_SPELLCAST_START','early')
assert(a.ballEmergencyEntry and a.rows[1].countdown:GetText()=='取消读条！')
assert(a.rows[1].skill:GetText()=='溜溜球' and a.rows[1].quota:GetText()=='')
assert(c.ballCast.event==nil and not e.consumed)
send('UNIT_SPELLCAST_STOP','early');assert(a.ballEmergencyEntry)
send('UNIT_SPELLCAST_SUCCEEDED','early');assert(not a.ballEmergencyEntry and not e.consumed)
-- Finishing an off-plan cast when a later slot opens cannot consume that slot.
now=26;send('UNIT_SPELLCAST_START','too-many') -- first slot still owed: legitimate late cast
send('UNIT_SPELLCAST_SUCCEEDED','too-many');assert(e.consumed)
now=26.1;send('UNIT_SPELLCAST_START','extra');assert(a.ballEmergencyEntry)
now=28;send('UNIT_SPELLCAST_SUCCEEDED','extra');assert(not next.consumed)
-- Superseded misses do not swallow the next board event.
e,next=setup();now=27;t:Update();assert(e.expired and not e.consumed)
send('UNIT_SPELLCAST_START','next');assert(c.ballCast.event==next)
now=29;send('UNIT_SPELLCAST_SUCCEEDED','next');assert(next.consumed and not e.consumed)
now=31;send('UNIT_SPELLCAST_START','after-last');assert(a.ballEmergencyEntry)
-- Ball emergency has its own owner; either clear preserves the other skill.
a:ShowEmergency('取消蓄力！','3/3',nil,false);local green=a.emergencyEntry
send('UNIT_SPELLCAST_FAILED','after-last');assert(a.emergencyEntry==green and not a.ballEmergencyEntry)
send('UNIT_SPELLCAST_START','again');assert(a.ballEmergencyEntry)
a:ClearEmergency();assert(a.ballEmergencyEntry)
EC.db.reminder.enabled=false;t:Update();assert(a.rows[1].countdown:GetText()=='取消读条！')
now=47;t:Update();assert(not a.ballEmergencyEntry and not c.ballCast)
EC.db.reminder.enabled=true
-- No personal ball plan: no cancellation authority. End-session clears warnings.
e=setup();t.snapshot.events={};send('UNIT_SPELLCAST_START','unplanned-board');assert(not c.ballCast and not a.ballEmergencyEntry)
e=setup();now=0;send('UNIT_SPELLCAST_START','stop-session');assert(a.ballEmergencyEntry)
t:Stop('test',true);assert(not a.ballEmergencyEntry and not c.ballCast)
''')
print('PASS ball text/UI correction: normal, persistent late, cast allowance, late retry, premature/extra cast cancellation, slot rollover, independent breath warning, no quota and no audio')

