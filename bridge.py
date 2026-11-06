"""Local Windows UIA JSON CLI and MCP stdio adapter. Standard library only."""
from __future__ import annotations
import argparse,json,os,subprocess,sys,time,uuid,base64,struct
from pathlib import Path
from datetime import datetime,timezone
if hasattr(sys.stdin,'reconfigure'):sys.stdin.reconfigure(encoding='utf-8-sig')
if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
ROOT=Path(__file__).resolve().parent
READ_COMMANDS={'list_windows','inspect','screenshot','capture_screen','action_status'}
def utc():return datetime.now(timezone.utc).isoformat()
def journal(row):
    directory=ROOT/'.state';directory.mkdir(exist_ok=True)
    with (directory/'actions.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(row)+'\n')
def execute(request:dict,timeout:float=18)->dict:
    if not isinstance(request,dict) or request.get('command') not in READ_COMMANDS|{'act'}:return {'ok':False,'error':'Unknown command'}
    action_id=uuid.uuid4().hex
    if request['command']=='action_status':
        job=request.get('job_id','')
        if len(job)!=32 or any(c not in '0123456789abcdef' for c in job):return {'ok':False,'error':'Invalid job_id'}
        directory=ROOT/'.state/jobs';result=directory/(job+'.json')
        if result.exists():return {**json.loads(result.read_text(encoding='utf-8')),'job_id':job,'job_complete':True}
        if not (directory/(job+'.submitted')).exists():return {'ok':False,'error':'Unknown job_id'}
        return {'ok':True,'status':'pending','job_id':job,'job_complete':False,'result':{'job_id':job,'note':'Invocation pending; inspect the UI. Do not submit the action again.'}}
    # Never journal UI names, input text, keyboard values, screenshots or credential-bearing content.
    audit={'id':action_id,'time_utc':utc(),'command':request['command'],'action':request.get('action'),'hwnd':request.get('hwnd')}
    if request['command']=='act':journal({**audit,'phase':'started'})
    powershell=Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    try:
        native=[str(powershell),'-NoLogo','-NoProfile','-NonInteractive','-STA','-File',str(ROOT/'worker.ps1')]
        use_com=request['command']=='inspect' or (request['command']=='act' and request.get('action') not in {'focus','key','click_point','hover_point'})
        command=native;payload=request
        if use_com:
            validation=subprocess.run(native,input=json.dumps({**request,'command':'guard'}),text=True,encoding='utf-8',capture_output=True,timeout=timeout,creationflags=subprocess.CREATE_NO_WINDOW)
            validated=json.loads(validation.stdout.strip())
            if not validated.get('ok'):
                if request['command']=='act':journal({**audit,'phase':'guard_refused','ok':False})
                return validated
            command=[str(ROOT/'.venv/Scripts/python.exe'),str(ROOT/'uia3_worker.py')];payload={**request,'_verified_window':validated['result']}
        if request['command']=='act' and request.get('action')=='invoke':
            directory=ROOT/'.state/jobs';directory.mkdir(parents=True,exist_ok=True);(directory/(action_id+'.submitted')).write_text(json.dumps({'time_utc':utc(),'hwnd':request['hwnd']}),encoding='utf-8')
            child=subprocess.Popen([sys.executable,str(ROOT/'invoke_supervisor.py')],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
            child.stdin.write(json.dumps({**payload,'_job_id':action_id}).encode('utf-8'));child.stdin.close()
            deadline=time.monotonic()+2
            target=directory/(action_id+'.json')
            while not target.exists() and time.monotonic()<deadline:time.sleep(.05)
            journal({**audit,'phase':'submitted','job_id':action_id})
            if target.exists():return {**json.loads(target.read_text(encoding='utf-8')),'job_id':action_id,'job_complete':True}
            return {'ok':True,'status':'pending','job_id':action_id,'job_complete':False,'result':{'action':'invoke','job_id':action_id,'window_hwnd':request['hwnd'],'note':'Provider invocation continues in a bounded child. Inspect resulting UI, handle any expected dialog, then query desktop_action_status. Do not invoke again.'}}
        process=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False),text=True,encoding='utf-8',capture_output=True,timeout=timeout,creationflags=subprocess.CREATE_NO_WINDOW)
        try:result=json.loads(process.stdout.strip())
        except json.JSONDecodeError:result={'ok':False,'error':'Worker did not return JSON','diagnostic':process.stderr.strip()[:1600]}
    except subprocess.TimeoutExpired:
        result={'ok':False,'status':'unknown_after_timeout','error':'Worker exceeded bounded timeout. Inspect current UI before any retry.','action_may_have_run':request['command']=='act'}
    if request['command']=='act':journal({**audit,'phase':'returned','ok':result.get('ok',False),'status':result.get('status')})
    return result
def schema(properties,required=()):return {'type':'object','properties':properties,'required':list(required),'additionalProperties':False}
STRING={'type':'string'}
WINDOW={'hwnd':STRING,'window_key':STRING}
TOOLS=[
 {'name':'desktop_list_windows','description':'List visible windows in the current Windows desktop session, optionally by exact process name/title substring. No actions. Titles have URL query values redacted. Use returned hwnd/window_key to scope every subsequent operation.','inputSchema':schema({'process':STRING,'title_contains':STRING}),'annotations':{'readOnlyHint':True,'openWorldHint':False}},
 {'name':'desktop_inspect','description':'Read a bounded UI Automation control tree for one verified window. Password control names are masked; field values are not collected. Returns stable element keys and supported patterns.','inputSchema':schema({**WINDOW,'max_nodes':{'type':'integer','minimum':1,'maximum':2500},'max_depth':{'type':'integer','minimum':0,'maximum':30}},WINDOW),'annotations':{'readOnlyHint':True,'openWorldHint':False}},
 {'name':'desktop_act','description':'Perform one explicit UI action in a freshly verified window. Prefer invoke/select/expand/toggle to pointer input. Element actions require element_key from inspect; point coordinates are relative to the window and require a fresh screenshot. Never dismiss an unseen dialog or bulk-close windows. Follow the normal user authorization/confirmation rules for the action; this tool does not authorize credentials, CAPTCHA, access changes, binding agreements, destructive actions or external communications. Always inspect after acting. A timeout may mean the action ran; do not retry blindly.','inputSchema':schema({**WINDOW,'action':{'type':'string','enum':['invoke','set_value','toggle','expand','collapse','select','close','focus','key','click','hover','click_point','hover_point']},'element_key':STRING,'value':STRING,'key':{'type':'string','enum':['Escape','Enter','Tab','ShiftTab','AltF4','Space','Up','Down','Left','Right','PageDown','PageUp','Home','End']},'x':{'type':'integer'},'y':{'type':'integer'}},['hwnd','window_key','action']),'annotations':{'readOnlyHint':False,'destructiveHint':True,'idempotentHint':False,'openWorldHint':False}},
 {'name':'desktop_screenshot','description':'Capture only the selected verified window to a fresh absolute PNG path. PrintWindow can return black for unsupported renderers; visually inspect. No whole-desktop fallback. Screenshot may contain private application content.','inputSchema':schema({**WINDOW,'output_path':STRING},['hwnd','window_key','output_path']),'annotations':{'readOnlyHint':True,'openWorldHint':False}}
]
COMMANDS=dict(zip([t['name'] for t in TOOLS],['list_windows','inspect','act','screenshot']))
TOOLS.append({'name':'desktop_capture_screen','description':'Capture a selected display (monitor_index0 by default, -1 for virtual desktop) to a fresh absolute PNG path. Returns physical-pixel bounds and cursor position for visual analysis. May contain private UI from other visible apps; prefer desktop_screenshot for one target window. Use a freshly verified window key for all subsequent pointer actions; screenshot coordinates alone do not authorize an action.','inputSchema':schema({'output_path':STRING,'monitor_index':{'type':'integer','minimum':-1}},['output_path']),'annotations':{'readOnlyHint':True,'openWorldHint':False}})
COMMANDS['desktop_capture_screen']='capture_screen'
TOOLS.append({'name':'desktop_action_status','description':'Read completion of a previously submitted UIA invoke job. Some providers wait until their modal dialog closes; inspect and handle that expected dialog rather than reinvoking. Jobs have a90-second bound.','inputSchema':schema({'job_id':STRING},['job_id']),'annotations':{'readOnlyHint':True,'openWorldHint':False}})
COMMANDS['desktop_action_status']='action_status'
def tool_call(name,arguments):
    if name not in COMMANDS:return {'content':[{'type':'text','text':'Unknown tool'}],'isError':True}
    result=execute({**arguments,'command':COMMANDS[name]})
    content=[{'type':'text','text':json.dumps(result,ensure_ascii=False)}]
    if name in {'desktop_screenshot','desktop_capture_screen'} and result.get('ok'):
        content.append({'type':'image','mimeType':'image/png','data':base64.b64encode(Path(result['result']['path']).read_bytes()).decode('ascii')})
    return {'content':content,'isError':not result.get('ok',False)}
def serve():
    for line in sys.stdin:
        if not line.strip():continue
        request=None
        try:
            request=json.loads(line);method=request.get('method');params=request.get('params') or {};request_id=request.get('id')
            if 'id' not in request:continue
            if method=='initialize':result={'protocolVersion':params.get('protocolVersion') if params.get('protocolVersion') in {'2024-11-05','2025-03-26','2025-06-18','2025-11-25'} else '2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'windows-ui-bridge','version':'0.1.0'},'instructions':'Local Windows desktop UI test helper. Inspect exact windows and controls, perform authorized actions, then inspect results. No blanket dialog dismissal or unrelated-window cleanup. Runs with the existing user/session token; no privilege elevation.'}
            elif method=='ping':result={}
            elif method=='tools/list':result={'tools':TOOLS}
            elif method=='tools/call':result=tool_call(params.get('name'),params.get('arguments') or {})
            else:
                print(json.dumps({'jsonrpc':'2.0','id':request_id,'error':{'code':-32601,'message':'Method not found'}}),flush=True);continue
            print(json.dumps({'jsonrpc':'2.0','id':request_id,'result':result},ensure_ascii=False),flush=True)
        except Exception as error:
            print(json.dumps({'jsonrpc':'2.0','id':request.get('id') if isinstance(request,dict) else None,'error':{'code':-32603,'message':str(error)}}),flush=True)
def main():
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['call','serve','info']);parser.add_argument('--request-file',type=Path)
    options=parser.parse_args()
    if options.mode=='info':print(json.dumps({'executable':sys.executable,'version':list(sys.version_info[:3]),'bits':struct.calcsize('P')*8,'platform':sys.platform}));return
    if options.mode=='serve':serve();return
    request=json.loads(options.request_file.read_text(encoding='utf-8-sig') if options.request_file else sys.stdin.read())
    result=execute(request);print(json.dumps(result,ensure_ascii=False));sys.exit(0 if result.get('ok') else 1)
if __name__=='__main__':main()
