"""Default TTS / bundled pack regression. Every sound API is mocked."""
from pathlib import Path
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
def runtime():
 r=LuaRuntime(unpack_returned_tuples=True)
 r.execute((ROOT/'tests/wow_mock.lua').read_text(encoding='utf-8'))
 r.execute('SlashCmdList={};SOUNDKIT={RAID_WARNING=1,ALARM_CLOCK_WARNING_3=2,READY_CHECK=3};wipe=function(t) for k in pairs(t) do t[k]=nil end end')
 for n in ['Core.lua','Features.lua','TTS.lua','Voice.lua','Runtime.lua','UI.lua']:
  r.execute((ROOT/n).read_text(encoding='utf-8-sig'),'EvokerCue',r.globals().EC)
 r.execute(r"""
now=0;GetTime=function() return now end
EC.GetGamePlayerIdentity=function() return {shortName='mock',fullName='mock-realm'} end
EC.RefreshPlayerIdentity=function() return identity end
messages={};print=function(text) messages[#messages+1]=text end
voices={{voiceID=8,name='Mandarin mock'},{voiceID=0,name='SFD default mock'}}
calls={};fileCalls={};soundCalls={};timers={};stops={}
C_VoiceChat={GetTtsVoices=function() return voices end,
 SpeakText=function(...) calls[#calls+1]={...} end,
 StopSpeakingText=function() error('MUST NOT stop global TTS') end}
PlaySoundFile=function(...) fileCalls[#fileCalls+1]={...};return true,987 end
StopSound=function(handle) stops[#stops+1]=handle end
PlaySound=function(...) soundCalls[#soundCalls+1]={...};return true,988 end
C_Timer.After=function(delay,callback) timers[#timers+1]={delay=delay,callback=callback} end
GetInstanceInfo=function() return 'city','none',0,0,0,0,0,zoneID or 0 end
function pump()
 local n=0
 while #timers>0 do n=n+1;assert(n<500);local item=table.remove(timers,1);item.callback() end
end
""")
 return r
r=runtime()
r.execute(r"""
-- Real DB initialization, entirely in memory; preserve old unrelated settings.
local plan={text='original note',draft='original draft'}
EvokerCueDB={enabled=false,voice={enabled=false,normalEnabled=false,correctionEnabled=false,channel='SFX'},sound={channel='Dialog',enabled=false},raidaryPlan={sentinel=plan},timeline={planSource='RAIDARY',customAliases={BALL='original alias'}},runtime={onlyVenomousAbyss=false},migration={sbgImported=true}}
EC:InitializeDB()
assert(EC.db.voice.backend=='TTS' and EC.db.voice.tts.rate==0 and EC.db.voice.tts.volume==100)
assert(not EC.db.enabled and not EC.db.voice.enabled and not EC.db.voice.normalEnabled and not EC.db.voice.correctionEnabled)
assert(EC.db.voice.channel=='SFX' and EC.db.sound.channel=='Dialog' and not EC.db.sound.enabled)
assert(EC.db.raidaryPlan.sentinel==plan and plan.text=='original note' and EC.db.timeline.customAliases.BALL=='original alias')
assert(EC.Voice:SetBackend('OGG'));EC:InitializeDB();assert(EC.db.voice.backend=='OGG')
assert(EC.Voice:SetBackend('TTS'));assert(not EC.Voice:SetBackend('invalid'))
-- Fresh defaults initialize without speech or changes to game TTS settings.
EvokerCueDB={};EC:InitializeDB();assert(EC.db.voice.backend=='TTS' and #calls==0 and #fileCalls==0)
EC.Voice:Initialize();EC.UI:CreateSoundPage(CreateFrame('Frame'));EC.UI:RefreshSound()
assert(EC.UI.voiceBackend and EC.UI.ttsVoice and EC.UI.ttsVoice.label:GetText():find('SFD default mock',1,true))
-- Ten actual voice buttons use the selected backend; the eleventh is a
-- separate game-alert test and intentionally remains PlaySound.
local tests={{'绿喷','绿喷'},{'静滞','静滞'},{'释放静滞','放静滞'},{'回溯','回溯'},{'微风','微风'},{'空间悖论','悖论'},{'时间螺旋','时间螺旋'},{'先别喷','先别喷'},{'绿喷晚啦','绿喷晚啦'},{'取消绿喷','取消绿喷'}}
assert(not EC.Runtime:IsZoneAllowed())
for _,item in ipairs(tests) do
 EC.Voice:Stop(true);local before=#calls;click(item[1]);assert(#calls==before+1)
 local c=calls[#calls];assert(c[1]==0 and c[2]==item[2] and c[3]==0 and c[4]==100 and c[5]==true)
end
assert(#fileCalls==0);click('测试警告音');assert(#soundCalls==1)
assert(EC.state.logs[1]:find('已提交TTS',1,true))
-- Automatic output retains the existing global / zone / per-kind limits.
EC.Voice:Stop(true);local before=#calls
assert(not EC.Voice:PlaySkill('STASIS',false));assert(not EC.Voice:PlaySpecial('EARLY',false,false));assert(#calls==before)
EC.db.enabled=false
local msg=#messages
for _,item in ipairs(tests) do click(item[1]) end
click('测试警告音');assert(#calls==before and #messages==msg+11)
EC.db.enabled=true;EC.db.runtime.onlyVenomousAbyss=false
EC.Voice:Stop(true);assert(EC.Voice:PlaySkill('STASIS',false));assert(#calls==before+1)
EC.db.voice.normalEnabled=false;EC.Voice:Stop(true);assert(not EC.Voice:PlaySkill('STASIS',false))
EC.db.voice.correctionEnabled=false;assert(not EC.Voice:PlaySpecial('EARLY',false,false))
EC.db.voice.enabled=false;assert(EC.Voice:PlaySkill('STASIS',true));EC.Voice:Stop(true)
-- Safe voice resolution: actual ID 0 preference, enumerated fallback,
-- explicit selection and missing-selection rejection. No language guessing.
voices={{voiceID=8,name='Mandarin mock'}};assert(EC.TTS:GetVoice()==8)
EC.db.voice.tts.voice=8;EC.db.voice.tts.rate=2;EC.db.voice.tts.volume=77
EC.Voice:PlaySkill('STASIS',true);local c=calls[#calls];assert(c[1]==8 and c[3]==2 and c[4]==77)
EC.Voice:Stop(true);EC.db.voice.tts.voice=55;before=#calls
assert(not EC.Voice:PlaySkill('STASIS',true) and #calls==before)
assert(messages[#messages]:find('内置语音包',1,true))
EC.db.voice.tts.voice='AUTO';EC.db.voice.tts.rate=0;EC.db.voice.tts.volume=100
voices={};assert(not EC.Voice:PlaySkill('STASIS',true));assert(#calls==before)
C_VoiceChat.GetTtsVoices=function() error('mock enumerate failure') end
assert(not EC.Voice:PlaySkill('STASIS',true))
C_VoiceChat=nil;assert(not EC.Voice:PlaySkill('STASIS',true))
-- Switching to OGG remains usable even without any TTS API.
assert(EC.Voice:SetBackend('OGG'))
for _,item in ipairs(tests) do local n=#fileCalls;EC.Voice:Stop(true);click(item[1]);assert(#fileCalls==n+1) end
local stopCount=#stops;EC.Voice:Stop(true);assert(#stops==stopCount+1 and stops[#stops]==987)
-- Actual backend selector controls persist the choice; enum list re-reads.
local function cycleBackend()
 for _,frame in ipairs(frames) do
  if frame.parent==EC.UI.voiceBackend and frame.label and frame.label:GetText()=='›' then frame:fire('OnClick');return end
 end
 error('backend arrow missing')
end
C_VoiceChat={GetTtsVoices=function() return {{voiceID=0,name='Default'},{voiceID=8,name='Mandarin mock'}} end,
 SpeakText=function(...) calls[#calls+1]={...} end,
 StopSpeakingText=function() error('global TTS stop forbidden') end}
cycleBackend();assert(EC.db.voice.backend=='TTS')
EC.UI.ttsVoice:fire('OnClick');click('Mandarin mock');assert(EC.db.voice.tts.voice==8)
EC.UI:RefreshSound();assert(EC.UI.ttsVoice.label:GetText()=='Mandarin mock')
-- Local queue: no global stop; stale owner drops; interruption/session stop
-- invalidates only EVC callbacks and queued cues. Already submitted speech
-- cannot safely be recalled by this void/global API.
EC.db.voice.enabled=true;EC.db.voice.normalEnabled=true;EC.db.voice.correctionEnabled=true
EC.db.voice.tts.voice='AUTO';EC.db.runtime.onlyVenomousAbyss=false
EC.Voice:Stop(true);pump();before=#calls
EC.Voice:PlaySkill('STASIS',true);EC.Voice:PlaySkill('REWIND',true)
assert(#calls==before+1 and #EC.Voice.queue==1)
pump();assert(#calls==before+2)
EC.Voice:PlaySkill('STASIS',true);EC.Voice:PlaySkill('REWIND',true);before=#calls
EC.Voice:Stop(true);pump();assert(#calls==before and #EC.Voice.queue==0)
EC.Voice:PlaySkill('STASIS',true);before=#calls
EC.Voice:PlaySpecial('CANCEL',true,true);assert(#calls==before+1)
EC.Voice:CancelCastWarning();EC.Voice:Stop(true);pump()
local snapshot={};local owner={time=5,consumed=false};now=0
EC.Timeline={active=true,snapshot=snapshot,GetElapsed=function() return now end}
EC.Voice:PlaySkill('STASIS',true);before=#calls
assert(EC.Voice:PlaySkill('REWIND',false,owner));owner.consumed=true;pump();assert(#calls==before)
-- No false audible-success claim on synchronous API errors / explicit false.
C_VoiceChat.SpeakText=function() error('mock speech failure') end
assert(not EC.Voice:PlaySkill('STASIS',true));assert(EC.state.logs[1]:find('TTS请求失败',1,true))
C_VoiceChat.SpeakText=function() return false end
assert(not EC.Voice:PlaySkill('STASIS',true))
EC.db.voice.tts.volume=0;assert(not EC.Voice:PlaySkill('STASIS',true))
assert(not EC.Features:SkillEnabled('BALL') and not EC.Features:DreamLoomEnabled())
assert(not EC.Voice:PlaySkill('BALL',true));assert(EC.VERSION=='0.8.14')
""")
print('PASS fresh/upgrade default TTS; one-time migration preserves old switches, channels, plan/alias data and later OGG choice')
print('PASS ten voice UI buttons through TTS with exact text/voice/rate/volume/overlap; independent game-alert test retained')
print('PASS test-outside-zone fix and automatic global/zone/per-kind gates for default TTS')
print('PASS enumerated voice 0 preference/fallback/manual selection; no API/no voices/stale ID/throw/false/zero-volume report failure')
print('PASS OGG selectable and all ten original assets usable without TTS API; OGG StopSound uses own handle')
print('PASS local queue, priority, stale-owner pruning, session/backend changes; no global TTS stop or CVar writes')
print('PASS source selector and dynamic voice selector; disabled features and version 0.8.14 unchanged')
# Full production load, with no API invocation or real game session.
f=LuaRuntime(unpack_returned_tuples=True);f.execute((ROOT/'tests/wow_mock.lua').read_text(encoding='utf-8'));f.execute('SlashCmdList={}')
for line in (ROOT/'EvokerCue.toc').read_text(encoding='utf-8').splitlines():
 if line.endswith('.lua'):f.execute((ROOT/line).read_text(encoding='utf-8-sig'),'EvokerCue',f.globals().EC)
f.execute('assert(EC.VERSION=="0.8.14" and EC.TTS and not EC.Features.ball and not EC.Features:DreamLoomEnabled())')
assert 'StopSpeakingText(' not in (ROOT/'TTS.lua').read_text(encoding='utf-8')
assert 'StopSpeakingText(' not in (ROOT/'Voice.lua').read_text(encoding='utf-8')
print('PASS full production TOC load with new independent TTS module and retained feature policy')
