"""Ball slot state/ownership tests against real handlers with simulated WoW APIs.
Includes integrity, model, persistence, UI and Lua 5.1 regression suites.
"""
from pathlib import Path
import runpy

base = runpy.run_path(str(Path(__file__).with_name('run_integrity_domains.py')))
r = base['r']
r.execute('''
local t,c,a=EC.Timeline,EC.CastTracker,EC.AlertUI
c:Initialize()
local secret={};EC.IsSecret=function(_,value) return value==secret end
local function fixture(times, complete)
 c:EndSession('fixture');a:ClearEmergency()
 local lines={}
 for _,time in ipairs(times or {30}) do lines[#lines+1]=string.format('00:%02d 测试奶龙 球',time) end
 if complete==false then lines[#lines+1]='00-50 测试奶龙 球' end
 local result=EC.Parser:BuildResult(table.concat(lines,'\\n'),identity)
 now=0;t.snapshot=t:BuildSnapshot(result);t.startTime=0;t.active=true;t.source='BOSS'
 c:BeginSession(t.snapshot,'BOSS',0);t:Update()
 return t.snapshot.events[1],t.snapshot.events[2]
end
local function at(time) now=time;t:Update() end
local function send(kind,guid,bar,unit,spell)
 c.eventFrame:fire('OnEvent','UNIT_SPELLCAST_'..kind,unit or 'player',guid,spell or 373861,bar)
end
local function text() return a.rows[1].countdown:GetText() end
local function invariant(event)
 assert(event.consumed==(event.ballState=='DONE'))
 assert(event.expired==(event.ballState=='MISSED'))
 assert((event.manualCastPending==true)==(event.ballState=='CASTING'))
 assert(event.reminderClosed==(event.ballState=='DONE' or event.ballState=='MISSED'))
end
-- 1. Normal success, including actual UI render state.
local e,n=fixture();assert(e.ballState=='WAITING');at(30)
assert(e.ballState=='DUE' and a.rows[1].skill:GetText()=='溜溜球')
send('START','normal');assert(e.ballState=='CASTING' and text()=='施法中')
send('SUCCEEDED','normal');assert(e.ballState=='DONE' and #t:GetVisibleEntries(now)==0);invariant(e)
-- 2/3. Missed due time remains retryable; late START is legal.
e=fixture();at(32);assert(e.ballState=='LATE' and text()=='溜溜球晚了')
at(33);send('START','late');assert(e.ballState=='CASTING' and not a.ballEmergencyEntry and text()=='施法中')
send('SUCCEEDED','late');assert(e.ballState=='DONE')
-- 4/5. Interrupted before/after deadline releases ownership; retry completes once.
e=fixture();at(30.2);send('START','A');at(30.8);send('INTERRUPTED','A');assert(e.ballState=='DUE')
at(31.3);send('START','B');assert(e.ballState=='CASTING')
send('SUCCEEDED','B');assert(e.ballState=='DONE');invariant(e)
e=fixture();at(30);send('START','A');at(32);send('FAILED','A');assert(e.ballState=='LATE')
send('START','B');send('SUCCEEDED','B');assert(e.ballState=='DONE')
-- 6/7. Illegal success never searches for a future slot, even across its window.
e=fixture();at(20);send('START','illegal')
assert(c.ballCast.disposition=='ILLEGAL' and c.ballCast.event==nil and text()=='取消读条！')
at(21);send('SUCCEEDED','illegal');assert(e.ballState=='WAITING');at(30);assert(e.ballState=='DUE')
e=fixture();at(26);send('START','illegal');at(28);send('SUCCEEDED','illegal');assert(e.ballState=='DUE' and not e.consumed)
-- 8. Unknown unassigned casts are explicitly neutral, with no future owner.
e=fixture(nil,false);at(20);send('START','unknown')
assert(c.ballCast.disposition=='UNASSIGNED_UNKNOWN' and not c.ballCast.event and not a.ballEmergencyEntry)
at(28);send('SUCCEEDED','unknown');assert(e.ballState=='DUE' and not e.consumed)
-- 9. DONE is terminal. Extra casts differ only in correction permission.
for _,complete in ipairs({true,false}) do
 e=fixture(nil,complete);at(30);send('START','one');send('SUCCEEDED','one')
 send('START','extra');assert((a.ballEmergencyEntry~=nil)==complete and c.ballCast.event==nil)
 send('SUCCEEDED','extra');assert(e.ballState=='DONE');invariant(e)
end
-- 10/11. CASTING wins across postHold and the former hold+2 boundary, also UNKNOWN.
for _,complete in ipairs({true,false}) do
 e=fixture(nil,complete);at(30);send('START','long')
 for _,time in ipairs({31,33,40}) do at(time);assert(e.ballState=='CASTING' and text()=='施法中');invariant(e) end
 send('SUCCEEDED','long');assert(e.ballState=='DONE')
end
-- 12. Duplicate START/SUCCESS, SUCCESS+STOP, and repeated STOP cannot reconsume.
e,n=fixture({30,35});at(30);send('START','one');send('SUCCEEDED','one')
at(33);send('START','one');send('SUCCEEDED','one');send('STOP','one');send('STOP','one')
assert(e.ballState=='DONE' and n.ballState=='DUE' and not c.ballCast)
send('START','one',999);assert(not c.ballCast and n.ballState=='DUE')
-- 13. Late A results do not touch B. STOP never asserts success or clears ownership.
e=fixture();at(30);send('START','A',101);send('INTERRUPTED','A',101);send('START','B',102)
for _,kind in ipairs({'STOP','SUCCEEDED','FAILED','INTERRUPTED','START'}) do
 send(kind,'A',101);assert(c.ballCast.castGUID=='B' and e.ballState=='CASTING')
end
send('STOP','B',102);assert(e.ballState=='CASTING')
send('SUCCEEDED','B',102);assert(e.ballState=='DONE')
-- 14. One manual cast completes one slot, including simultaneous planned times.
e,n=fixture({30,30});at(30);send('START','first');assert(c.ballCast.event==e)
send('SUCCEEDED','first');assert(e.ballState=='DONE' and n.ballState=='DUE')
send('START','second');assert(c.ballCast.event==n);send('SUCCEEDED','second');assert(n.ballState=='DONE')
-- 15. Preserve old product rule: B opens -> unstarted A MISSED; new START owns B.
e,n=fixture({30,35});at(31);assert(e.ballState=='LATE')
now=32;send('START','B') -- selection must enforce rollover even without an Update tick
assert(e.ballState=='MISSED' and c.ballCast.event==n and n.ballState=='CASTING')
send('SUCCEEDED','B');assert(n.ballState=='DONE' and not e.consumed)
-- A already casting retains ownership across B's lead window.
e,n=fixture({30,35});at(30);send('START','A');at(33)
assert(e.ballState=='CASTING' and n.ballState=='DUE' and #t:GetVisibleEntries(now)==2)
send('SUCCEEDED','A');assert(e.ballState=='DONE' and n.ballState=='DUE')
send('START','B');assert(c.ballCast.event==n);send('SUCCEEDED','B');assert(n.ballState=='DONE')
-- If A fails after B opens, A is MISSED; retry belongs to B, never both.
e,n=fixture({30,35});at(30);send('START','A');at(33);send('FAILED','A')
assert(e.ballState=='MISSED');send('START','B');assert(c.ballCast.event==n)
-- 16. Copied success without the same manual START is observational only.
e=fixture();at(30);send('SUCCEEDED','copy');assert(e.ballState=='DUE')
send('START','manual');send('SUCCEEDED','copy');assert(e.ballState=='CASTING')
send('SUCCEEDED','manual');assert(e.ballState=='DONE')
-- Non-player, unreadable, conflicting and absent identities are never ownership evidence.
e=fixture();at(30);send('START','other',nil,'party1');send('START',secret);send('START',nil)
assert(e.ballState=='DUE' and not c.ballCast)
send('START','owned',201);send('SUCCEEDED','owned',202);send('FAILED','wrong',201)
send('SUCCEEDED','owned',201,'party1');send('START','owned',202)
assert(e.ballState=='CASTING' and c.ballCast.castBarID==201)
send('SUCCEEDED',secret);assert(e.ballState=='CASTING')
send('SUCCEEDED','owned',201);assert(e.ballState=='DONE')
-- Bar-only identity can work, but never on an unpaired success.
e=fixture();at(30);send('START',nil,301);send('SUCCEEDED',nil,302);assert(e.ballState=='CASTING')
send('SUCCEEDED',nil,301);assert(e.ballState=='DONE')
-- A reused bar key alone cannot distinguish an old result from the new owner.
e,n=fixture({30,35});at(30);send('START','A',401);send('SUCCEEDED','A',401)
at(33);send('START','B',401);send('SUCCEEDED',nil,401);assert(n.ballState=='CASTING')
send('SUCCEEDED','B',401);assert(n.ballState=='DONE')
-- Watchdog is an explicit lost-result cleanup, never a synthetic success.
e=fixture();at(30);send('START','lost');at(46);assert(e.ballState=='LATE' and not c.ballCast)
send('SUCCEEDED','lost');assert(e.ballState=='LATE')
send('START','retry');send('SUCCEEDED','retry');assert(e.ballState=='DONE')
-- Generic same-spell dismissal cannot bypass the state machine.
e=fixture();at(30);t:DismissActiveEvent('BALL','test');assert(e.ballState=='DUE')
-- Emergency UI ownership remains independent of green Breath.
e=fixture();at(20);a:ShowEmergency('取消蓄力！','3/3',nil,false);local green=a.emergencyEntry
send('START','illegal');assert(a.ballEmergencyEntry and a.emergencyEntry==green)
send('FAILED','illegal');assert(not a.ballEmergencyEntry and a.emergencyEntry==green)
-- Session/death cleanup releases the owner without completing it.
e=fixture();at(30);send('START','dead');c.eventFrame:fire('OnEvent','PLAYER_DEAD');assert(not c.ballCast and not e.consumed)
e=fixture();at(30);send('START','old');t:Stop('test',true);send('SUCCEEDED','old');assert(not e.consumed)
''')
print('PASS BALL_SLOT_STATE_MACHINE: 16 requested cases plus identities, same-time ties, rollover without tick, concurrent reminders, cleanup and generic-dismiss protection')
