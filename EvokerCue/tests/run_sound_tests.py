"""Sound-page tests use mocked APIs only: no device audio, no SavedVariables I/O."""
from pathlib import Path
import re,struct,hashlib
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
r=LuaRuntime(unpack_returned_tuples=True)
r.execute((ROOT/'tests/wow_mock.lua').read_text(encoding='utf-8'))
r.execute('SlashCmdList={};SOUNDKIT={RAID_WARNING=1,ALARM_CLOCK_WARNING_3=2,READY_CHECK=3};wipe=function(t) for k in pairs(t) do t[k]=nil end end')
for name in ['Core.lua','Features.lua','Runtime.lua','Voice.lua','UI.lua']:
 r.execute((ROOT/name).read_text(encoding='utf-8-sig'),'EvokerCue',r.globals().EC)
r.execute(r"""
EC.db=EC.defaults;EC.state.dbReady=true;EC.db.voice.backend="OGG"
local zoneID=0
GetInstanceInfo=function() return 'Mock zone','none',0,0,0,0,0,zoneID end
local fileCalls,soundCalls,prints=0,0,0
local paths,channels={},{ }
PlaySoundFile=function(path,channel)
 fileCalls=fileCalls+1;paths[#paths+1]=path;channels[#channels+1]=channel;return true,123
end
PlaySound=function(sound,channel) soundCalls=soundCalls+1;channels[#channels+1]=channel;return true,124 end
C_Timer.After=function() end
local originalPrint=print
print=function(text) assert(text:find('插件总开关已关闭',1,true));prints=prints+1 end
EC.Voice:Initialize();EC.UI:CreateSoundPage(CreateFrame('Frame'))
local labels={'绿喷','静滞','释放静滞','回溯','微风','空间悖论','时间螺旋','先别喷','绿喷晚啦','取消绿喷','测试警告音'}
local function test(expected)
 local beforeFiles,beforeSounds=fileCalls,soundCalls
 for _,label in ipairs(labels) do EC.Voice:Stop(true);click(label) end
 assert(fileCalls-beforeFiles==(expected and 10 or 0))
 assert(soundCalls-beforeSounds==(expected and 1 or 0))
end
-- Default raid-only scope does not silence explicit previews in cities.
assert(EC.db.runtime.onlyVenomousAbyss and not EC.Runtime:IsZoneAllowed())
for _,channel in ipairs({'Master','SFX','Dialog'}) do
 EC.db.voice.channel=channel;EC.db.sound.channel=channel;test(true)
 for i=#channels-10,#channels do assert(channels[i]==channel) end
end
assert(prints==0 and paths[1]=='Interface\\AddOns\\EvokerCue\\Sounds\\dream_breath.ogg')
-- Automatic outputs still obey the zone boundary and do not print test notices.
local function automatic(expected)
 local a,b=fileCalls,soundCalls
 EC.Voice:Stop(true);EC.Voice:PlaySkill('STASIS',false)
 EC.Voice:Stop(true);EC.Voice:PlaySpecial('EARLY',false,false)
 EC:PlayAlertSound(false)
 assert(fileCalls-a==(expected and 2 or 0) and soundCalls-b==(expected and 1 or 0))
end
automatic(false);assert(prints==0)
EC.db.enabled=false;test(false);assert(prints==11);automatic(false);assert(prints==11)
EC.db.enabled=true
-- Force remains isolated to previews: all sub-switches can be off.
EC.db.voice.enabled=false;EC.db.voice.normalEnabled=false;EC.db.voice.correctionEnabled=false;EC.db.reminder.enabled=false;EC.db.sound.enabled=false
test(true);automatic(false)
EC.db.runtime.onlyVenomousAbyss=false;automatic(false)
EC.db.voice.enabled=true;EC.db.voice.normalEnabled=true;EC.db.voice.correctionEnabled=true;EC.db.reminder.enabled=true;EC.db.sound.enabled=true
automatic(true)
EC.db.runtime.onlyVenomousAbyss=true
for _,id in ipairs({3004,2987,3095}) do zoneID=id;test(true);automatic(true) end
-- Per-kind switches remain authoritative for normal automatic playback.
EC.Voice:Stop(true);local a,b=fileCalls,soundCalls
EC.db.voice.normalEnabled=false;assert(not EC.Voice:PlaySkill('STASIS',false))
EC.db.voice.correctionEnabled=false;assert(not EC.Voice:PlaySpecial('EARLY',false,false))
EC.db.sound.enabled=false;EC:PlayAlertSound(false)
assert(fileCalls==a and soundCalls==b)
-- Failure is logged, never interpreted as successful audible playback.
EC.db.voice.normalEnabled=true
PlaySoundFile=function() return false,nil end
EC.Voice:Stop(true);EC.Voice:PlaySkill('STASIS',true)
assert(EC.state.logs[1]:find('语音播放失败',1,true))
assert(not EC.Features:SkillEnabled('BALL') and not EC.Features:DreamLoomEnabled())
assert(not EC.Voice:PlaySkill('BALL',true))
assert(EC.VERSION=='0.8.11')
print=originalPrint
""")
print('PASS 11 real UI buttons outside raid on Master/SFX/Dialog; 10 file previews plus one game alert per pass')
print('PASS global switch off: zero playback and 11 explicit notices; automatic calls remain silent')
print('PASS automatic audio obeys zone/global/per-kind switches; no forced automatic call sites')
print('PASS three whitelisted raids and unrestricted-zone setting allow normal automatic audio')
print('PASS preview bypasses sub-switches only; failure logged; disabled BALL/DreamLoom stay disabled')
# Container checks validate exact packaged filenames and integrity without playing audio.
crc_table=[]
for i in range(256):
 v=i<<24
 for _ in range(8):v=((v<<1)^0x04c11db7 if v&0x80000000 else v<<1)&0xffffffff
 crc_table.append(v)
def crc(data):
 v=0
 for byte in data:v=((v<<8)&0xffffffff)^crc_table[((v>>24)&255)^byte]
 return v
names=re.findall(r'file = "([^"]+\.ogg)"',(ROOT/'Voice.lua').read_text(encoding='utf-8'))
assert len(names)==10 and len(set(names))==10
actual={p.name for p in (ROOT/'Sounds').glob('*.ogg')};assert actual==set(names)
for name in names:
 data=(ROOT/'Sounds'/name).read_bytes();off=0;last_granule=0
 while off<len(data):
  assert data[off:off+4]==b'OggS' and data[off+4]==0
  n=data[off+26];size=27+n+sum(data[off+27:off+27+n]);page=bytearray(data[off:off+size]);assert len(page)==size
  checksum=struct.unpack_from('<I',page,22)[0];page[22:26]=b'\0'*4;assert crc(page)==checksum
  granule=struct.unpack_from('<Q',page,6)[0]
  if granule != 0xffffffffffffffff:last_granule=max(last_granule,granule)
  off+=size
 k=data.index(b'\x01vorbis');assert data[k+11]==1 and struct.unpack_from('<I',data,k+12)[0]==44100
 assert 0.1<last_granule/44100<3
assert '## Interface: 120105' in (ROOT/'EvokerCue.toc').read_text(encoding='utf-8')
assert '## Version: 0.8.11' in (ROOT/'EvokerCue.toc').read_text(encoding='utf-8')
print('PASS all 10 OGG files: exact case, Ogg page CRC, mono 44100Hz, valid duration; path derived from addon name')
print('PASS version 0.8.11 and Interface 120105 declarations')
