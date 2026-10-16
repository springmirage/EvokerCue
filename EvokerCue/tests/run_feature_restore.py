"""Run the existing complete suite with the central policy explicitly restored."""
from pathlib import Path
import runpy
import lupa.lua51
RealRuntime=lupa.lua51.LuaRuntime
class RestoredRuntime:
    def __init__(self,*args,**kwargs): self.inner=RealRuntime(*args,**kwargs)
    def __getattr__(self,name): return getattr(self.inner,name)
    def execute(self,code,*args):
        value=self.inner.execute(code,*args)
        if code.startswith('-- Lightweight API harness:') or code.strip()=='EC={}':
            root=Path(__file__).resolve().parents[1]
            self.inner.execute((root/'Features.lua').read_text(encoding='utf-8'),'EvokerCue',self.inner.globals().EC)
            self.inner.execute('EC.Features.ball=true;EC.Features.dreamLoom=true')
        return value
lupa.lua51.LuaRuntime=RestoredRuntime
runpy.run_path(str(Path(__file__).with_name('run_ball_slots.py')))
print('PASS restoration: complete existing suite with both central policy switches enabled')
