"""UIA3 COM control operations; invoked only after native window guard validation."""
import sys,json,os,ctypes,hashlib,re,time
from pathlib import Path
from collections import deque
from ctypes import wintypes as W
sys.stdin.reconfigure(encoding='utf-8');sys.stdout.reconfigure(encoding='utf-8')
ROOT=Path(__file__).resolve().parent
import comtypes.client
comtypes.client.gen_dir=str(ROOT/'.state/comtypes-gen');Path(comtypes.client.gen_dir).mkdir(parents=True,exist_ok=True)
UIA=comtypes.client.GetModule(str(Path(os.environ['WINDIR'])/'System32/UIAutomationCore.dll'))
api=comtypes.client.CreateObject(UIA.CUIAutomation,interface=UIA.IUIAutomation)
user=ctypes.WinDLL('user32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
try:
    user.SetProcessDpiAwarenessContext.argtypes=[W.HANDLE];user.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
except AttributeError:pass
user.GetWindowThreadProcessId.argtypes=[W.HWND,ctypes.POINTER(W.DWORD)];user.GetWindowTextW.argtypes=[W.HWND,W.LPWSTR,ctypes.c_int];user.IsWindow.argtypes=[W.HWND];user.GetForegroundWindow.restype=W.HWND;user.SetForegroundWindow.argtypes=[W.HWND]
kernel.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];kernel.OpenProcess.restype=W.HANDLE;kernel.GetProcessTimes.argtypes=[W.HANDLE,ctypes.POINTER(W.FILETIME),ctypes.POINTER(W.FILETIME),ctypes.POINTER(W.FILETIME),ctypes.POINTER(W.FILETIME)];kernel.CloseHandle.argtypes=[W.HANDLE]
class POINT(ctypes.Structure):_fields_=[('x',W.LONG),('y',W.LONG)]
user.GetCursorPos.argtypes=[ctypes.POINTER(POINT)]
user.SendMessageTimeoutW.argtypes=[W.HWND,W.UINT,W.WPARAM,W.LPARAM,W.UINT,W.UINT,ctypes.POINTER(ctypes.c_size_t)];user.SendMessageTimeoutW.restype=ctypes.c_size_t
user.WindowFromPoint.argtypes=[POINT];user.WindowFromPoint.restype=W.HWND;user.GetAncestor.argtypes=[W.HWND,W.UINT];user.GetAncestor.restype=W.HWND
def sha(s):return hashlib.sha256(s.encode()).hexdigest()
def scrub(s):return re.sub(r'([?&][A-Za-z0-9_]+)=([^&\s"<>]+)',r'\1=[redacted]',s or '')
def guard(window):
    h=int(window['hwnd']);pid=W.DWORD();user.GetWindowThreadProcessId(h,ctypes.byref(pid))
    if not user.IsWindow(h) or pid.value!=window['pid']:raise ValueError('Window process identity changed')
    s=ctypes.create_unicode_buffer(4096);user.GetWindowTextW(h,s,len(s))
    if sha(s.value)!=window['title_sha256']:raise ValueError('Window title changed; inspect again')
    process=kernel.OpenProcess(0x1000,False,pid.value)
    try:
        c,e,k,u=W.FILETIME(),W.FILETIME(),W.FILETIME(),W.FILETIME()
        if not process or not kernel.GetProcessTimes(process,ctypes.byref(c),ctypes.byref(e),ctypes.byref(k),ctypes.byref(u)):raise ValueError('Could not verify process creation time')
        if str((c.dwHighDateTime<<32)|c.dwLowDateTime)!=window['process_start_filetime']:raise ValueError('Process lifetime changed')
    finally:
        if process:kernel.CloseHandle(process)
    return h
PATTERNS={'invoke':('UIA_InvokePatternId','IUIAutomationInvokePattern'),'set_value':('UIA_ValuePatternId','IUIAutomationValuePattern'),'toggle':('UIA_TogglePatternId','IUIAutomationTogglePattern'),'expand':('UIA_ExpandCollapsePatternId','IUIAutomationExpandCollapsePattern'),'collapse':('UIA_ExpandCollapsePatternId','IUIAutomationExpandCollapsePattern'),'select':('UIA_SelectionItemPatternId','IUIAutomationSelectionItemPattern'),'close':('UIA_WindowPatternId','IUIAutomationWindowPattern')}
def pattern(el,action):
    constant,interface=PATTERNS[action];unknown=el.GetCurrentPattern(getattr(UIA,constant))
    if not unknown:raise ValueError('Required control pattern unavailable; no fallback action performed')
    return unknown.QueryInterface(getattr(UIA,interface))
def info(el,window,depth):
    name=el.CurrentName or '';runtime='.'.join(map(str,el.GetRuntimeId()));control=int(el.CurrentControlType);password=bool(el.CurrentIsPassword);r=el.CurrentBoundingRectangle
    available=[]
    for action in ('invoke','set_value','toggle','expand','select','close'):
        try:pattern(el,action);available.append(action)
        except Exception:pass
    row={'element_key':sha(window['window_key']+'|'+runtime+'|'+name+'|'+str(control)),'runtime_id':runtime,'name':'[password control]' if password else scrub(name),'automation_id':el.CurrentAutomationId or '','control_type':control,'class_name':el.CurrentClassName or '','pid':el.CurrentProcessId,'enabled':bool(el.CurrentIsEnabled),'offscreen':bool(el.CurrentIsOffscreen),'is_password':password,'depth':depth,'bounds':{'x':r.left,'y':r.top,'width':r.right-r.left,'height':r.bottom-r.top},'patterns':available}
    if 'toggle' in available:row['toggle_state']=int(pattern(el,'toggle').CurrentToggleState)
    if 'expand' in available:row['expand_collapse_state']=int(pattern(el,'expand').CurrentExpandCollapseState)
    if 'select' in available:row['selected']=bool(pattern(el,'select').CurrentIsSelected)
    return row
def walk(root,window,max_nodes=350,max_depth=12,find=None):
    walker=api.ControlViewWalker;queue=deque([(root,0)]);rows=[];deadline=time.monotonic()+10
    while queue and len(rows)<max_nodes and time.monotonic()<deadline:
        el,depth=queue.popleft()
        try:row=info(el,window,depth)
        except Exception:continue
        if find and row['element_key']==find:return el
        rows.append(row)
        if depth>=max_depth:continue
        try:
            child=walker.GetFirstChildElement(el)
            while child:
                queue.append((child,depth+1));child=walker.GetNextSiblingElement(child)
        except Exception:pass
    if find:raise ValueError('Element identity not found; inspect again. No action performed.')
    return {'elements':rows,'nodes':len(rows),'truncated':bool(queue),'max_depth':max_depth,'window':window,'backend':'Windows UI Automation COM/UIA3'}
def main(request):
    window=request.pop('_verified_window');h=guard(window);root=api.ElementFromHandle(h)
    if request['command']=='inspect':
        count=int(request.get('max_nodes',350));depth=int(request.get('max_depth',12))
        if not 1<=count<=2500 or not 0<=depth<=30:raise ValueError('Inspection bounds out of range')
        return walk(root,window,count,depth)
    action=request['action']
    if action=='close':el=root
    else:
        if not request.get('element_key'):raise ValueError('element_key from a fresh inspection is required')
        el=walk(root,window,2500,30,request['element_key'])
        if not el.CurrentIsEnabled or el.CurrentIsOffscreen:raise ValueError('Control disabled or offscreen; action refused')
    guard(window)
    if action=='set_value':
        if el.CurrentIsPassword:raise ValueError('Password controls are excluded; use the normal user credential handoff.')
        p=pattern(el,action)
        if p.CurrentIsReadOnly:raise ValueError('Control is readonly')
        p.SetValue(str(request.get('value','')))
    elif action in ('click','hover'):
        user.SetForegroundWindow(h)
        reply=ctypes.c_size_t()
        if not user.SendMessageTimeoutW(h,0,0,0,2,2000,ctypes.byref(reply)):raise ValueError('Target did not acknowledge activation within bounded timeout; input refused')
        if user.GetForegroundWindow()!=h:raise ValueError('Target foreground could not be verified')
        r=el.CurrentBoundingRectangle;x=int((r.left+r.right)/2);y=int((r.top+r.bottom)/2)
        if user.GetAncestor(user.WindowFromPoint(POINT(x,y)),2)!=h:raise ValueError('Pointer target is covered by another window')
        user.SetCursorPos(x,y)
        time.sleep(.12)
        guard(window)
        actual=POINT();user.GetCursorPos(ctypes.byref(actual))
        if abs(actual.x-x)>3 or abs(actual.y-y)>3 or user.GetForegroundWindow()!=h or user.GetAncestor(user.WindowFromPoint(actual),2)!=h:raise ValueError('Pointer/foreground changed before input; action refused')
        if action=='click':user.mouse_event(2,0,0,0,0);user.mouse_event(4,0,0,0,0)
    else:
        p=pattern(el,action);getattr(p,{'invoke':'Invoke','toggle':'Toggle','expand':'Expand','collapse':'Collapse','select':'Select','close':'Close'}[action])()
    return {'action':action,'window_hwnd':str(h),'window_exists_after':bool(user.IsWindow(h)),'backend':'Windows UI Automation COM/UIA3','note':'Action returned; inspect resulting UI before deciding workflow success.'}
if __name__=='__main__':
    try:print(json.dumps({'ok':True,'result':main(json.load(sys.stdin))},ensure_ascii=False))
    except Exception as error:print(json.dumps({'ok':False,'error':str(error)},ensure_ascii=False));sys.exit(1)
