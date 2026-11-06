"""Bounded child for UIA Invoke providers that wait until a modal dialog closes."""
import json,sys,subprocess,os
from pathlib import Path
sys.stdin.reconfigure(encoding='utf-8');sys.stdout.reconfigure(encoding='utf-8')
ROOT=Path(__file__).resolve().parent
request=json.load(sys.stdin);job=request.pop('_job_id');directory=ROOT/'.state/jobs';directory.mkdir(parents=True,exist_ok=True)
target=directory/(job+'.json')
def save(result):
    temp=target.with_suffix('.tmp');temp.write_text(json.dumps(result),encoding='utf-8');temp.replace(target)
try:
    process=subprocess.run([str(ROOT/'.venv/Scripts/python.exe'),str(ROOT/'uia3_worker.py')],input=json.dumps(request),text=True,encoding='utf-8',capture_output=True,timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
    try:result=json.loads(process.stdout.strip())
    except json.JSONDecodeError:result={'ok':False,'error':'UIA invocation worker returned no JSON','diagnostic':process.stderr[:1200]}
    save(result)
except subprocess.TimeoutExpired:save({'ok':False,'status':'unknown_after_timeout','action_may_have_run':True,'error':'Invocation reached90-second bound; inspect UI before any further action.'})
except Exception as error:save({'ok':False,'error':str(error)})
