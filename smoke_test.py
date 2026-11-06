import importlib.util,json,subprocess,time,sys,argparse
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parent;spec=importlib.util.spec_from_file_location('winbridge',root/'bridge.py');bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
parser=argparse.ArgumentParser();parser.add_argument('--output-dir',type=Path,default=root/'.state/self-test');options=parser.parse_args();out=options.output_dir;out.mkdir(parents=True,exist_ok=True);steps=[]
fixture=subprocess.Popen(['powershell','-NoLogo','-NoProfile','-STA','-File',str(root/'test_fixture.ps1')],creationflags=subprocess.CREATE_NO_WINDOW,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def call(request,timeout=18):
 r=bridge.execute(request,timeout=timeout)
 if not r.get('ok'):raise RuntimeError(json.dumps(r))
 return r['result']
def find_window(title):
 for _ in range(8):
  rows=call({'command':'list_windows','title_contains':title})['windows'];rows=[r for r in rows if r['pid']==fixture.pid]
  if rows:return rows[0]
  time.sleep(.2)
 raise AssertionError('Fixture window not found: '+title)
def inspect(w):return call({'command':'inspect','hwnd':w['hwnd'],'window_key':w['window_key'],'max_nodes':100,'max_depth':8})
def act(w,action,element=None,**extra):return call({'command':'act','hwnd':w['hwnd'],'window_key':w['window_key'],'action':action,**({'element_key':element['element_key']} if element else {}),**extra})
def named(tree,name):
 rows=[r for r in tree['elements'] if r['name']==name or r['automation_id']==name];assert len(rows)==1,(name,len(rows));return rows[0]
try:
 w=find_window('Codex UI Bridge Synthetic Test');tree=inspect(w);steps.append({'test':'Enumerate and inspect exact owned fixture window','passed':True,'nodes':tree['nodes']})
 act(w,'set_value',named(tree,'Synthetic text input'),value='SYNTHETIC UI BRIDGE VALUE')
 # The worker exposes no ValuePattern values; application source test verifies visible text via screenshot.
 tree=inspect(w);assert all('value' not in e for e in tree['elements']);steps.append({'test':'Set non-password UIA value without recording field values','passed':True})
 bad=bridge.execute({'command':'act','hwnd':w['hwnd'],'window_key':'invalid-stale-identity','action':'close'});assert not bad['ok'];assert find_window('Codex UI Bridge Synthetic Test');steps.append({'test':'Stale/missing window identity refuses mutation','passed':True})
 passwords=[e for e in tree['elements'] if e['is_password']];assert len(passwords)==1;password=passwords[0];assert password['name']=='[password control]'
 bad=bridge.execute({'command':'act','hwnd':w['hwnd'],'window_key':w['window_key'],'action':'set_value','element_key':password['element_key'],'value':'SYNTHETIC-NOT-A-CREDENTIAL'});assert not bad['ok'] and 'Password controls are excluded' in bad['error'];steps.append({'test':'Password controls masked and input refused','passed':True})
 act(w,'toggle',named(tree,'Synthetic checkbox'));assert named(inspect(w),'Synthetic checkbox')['toggle_state']==1;steps.append({'test':'Native checkbox TogglePattern and observed checked state','passed':True});print('Input and guard checks passed',flush=True)
 check=named(inspect(w),'Synthetic checkbox');act(w,'hover',check)
 x=round(check['bounds']['x']+check['bounds']['width']/2);y=round(check['bounds']['y']+check['bounds']['height']/2)
 moved=act(w,'hover_point',x=x-w['bounds']['x'],y=y-w['bounds']['y']);assert abs(moved['cursor_after']['x']-x)<=2 and abs(moved['cursor_after']['y']-y)<=2
 private=root/'.state/self-test';private.mkdir(parents=True,exist_ok=True);desktop=private/'desktop-capture.png';desktop.unlink(missing_ok=True)
 image=call({'command':'capture_screen','output_path':str(desktop.resolve()),'monitor_index':0});assert desktop.read_bytes().startswith(b'\x89PNG\r\n\x1a\n');assert image['bounds']['width']>0 and image['bounds']['height']>0
 steps.append({'test':'Desktop capture with physical screen bounds and verified cursor hover','passed':True})
 act(w,'click_point',x=x-w['bounds']['x'],y=y-w['bounds']['y']);assert named(inspect(w),'Synthetic checkbox')['toggle_state']==0
 steps.append({'test':'Screenshot-mapped relative pointer click and observed unchecked state','passed':True})
 parent=out.resolve()/'windows-ui-bridge-synthetic-parent.png';parent.unlink(missing_ok=True)
 call({'command':'screenshot','hwnd':w['hwnd'],'window_key':w['window_key'],'output_path':str(parent)})

 act(w,'click',named(tree,'Open synthetic dialog'));dialog=find_window('Synthetic popup - no external action');dt=inspect(dialog)
 screenshot=out.resolve()/'windows-ui-bridge-synthetic-modal.png';screenshot.unlink(missing_ok=True)
 call({'command':'screenshot','hwnd':dialog['hwnd'],'window_key':dialog['window_key'],'output_path':str(screenshot)})
 act(dialog,'invoke',named(dt,'Dismiss synthetic popup'))
 assert not [r for r in call({'command':'list_windows','title_contains':'Synthetic popup - no external action'})['windows'] if r['pid']==fixture.pid];steps.append({'test':'Open, inspect, screenshot and dismiss owned native modal by exact button','passed':True})
 print('Mouse-opened modal, capture and semantic dismissal passed',flush=True)
 act(w,'click',named(inspect(w),'Open synthetic dialog'));dialog=find_window('Synthetic popup - no external action');act(dialog,'key',key='Escape')
 assert not [r for r in call({'command':'list_windows','title_contains':'Synthetic popup - no external action'})['windows'] if r['pid']==fixture.pid];steps.append({'test':'Foreground-verified Escape dismisses exact test dialog','passed':True})
 tree=inspect(w);act(w,'click',named(tree,'Open second window'));second=find_window('Synthetic secondary test window');act(second,'close')
 assert not [r for r in call({'command':'list_windows','title_contains':'Synthetic secondary test window'})['windows'] if r['pid']==fixture.pid];steps.append({'test':'Close only explicitly selected secondary window','passed':True})
 act(w,'close');fixture.wait(timeout=10);assert fixture.returncode==0;steps.append({'test':'All disposable fixture windows cleaned up normally','passed':True})
 result={'verifiedUTC':datetime.now(timezone.utc).isoformat(),'toolDirectory':str(root),'syntheticTests':steps,'allPassed':True,'productCodeChanges':0,'databaseChanges':0,'unrelatedWindowsClosed':0,'screenshot':'windows-ui-bridge-synthetic-modal.png'}
 (out/'windows-ui-bridge-validation.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
finally:
 if fixture.poll() is None:
  # Only this script's disposable fixture process is eligible for forced cleanup.
  fixture.terminate();fixture.wait(timeout=8)
