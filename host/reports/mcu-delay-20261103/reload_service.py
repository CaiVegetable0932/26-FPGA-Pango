"""Load the rollback and delayed MCU dispatch while preserving the idle MCU and receiver setup."""
import json,urllib.request,time,subprocess
from pathlib import Path
base='http://127.0.0.1:8765';report=Path(__file__).resolve().parent

def read(route):
    with urllib.request.urlopen(base+route,timeout=10) as response:return json.load(response)

def post(route,data,token):
    request=urllib.request.Request(base+route,data=json.dumps(data).encode(),headers={'Content-Type':'application/json','X-Pango-Token':token},method='POST')
    with urllib.request.urlopen(request,timeout=20) as response:return json.load(response)

before=read('/api/mcu/status');receiver=read('/api/status?summary=1')
assert not before.get('connected') or before.get('state',{}).get('motion_state')==0, 'MCU is not idle'
assert before.get('zero_operation',{}).get('status')!='pending','MCU zero operation pending'
(report/'reload-before.json').write_text(json.dumps(dict(mcu=before,receiver=receiver),ensure_ascii=False,indent=2)+'\n')
subprocess.run(['systemctl','--user','restart','pango-host.service'],check=True)
# The existing login wrapper waits up to 45 seconds when the FPGA UART is absent.
for attempt in range(58):
    try:session=read('/api/session');break
    except OSError:time.sleep(1)
else:raise RuntimeError('service did not return')
token=session['token']
if before.get('connected'):
    state=post('/api/mcu/connect',dict(port=before['port']),token);assert state['connected'],state
if receiver.get('running') and not read('/api/status?summary=1')['running']:
    post('/api/start',dict(config=receiver['config'],auto_mock=False,archive_every=0),token)
time.sleep(2)
result=dict(mcu_connected=read('/api/mcu/status')['connected'],receiver=read('/api/status?summary=1')['signal'])
(report/'activation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False),flush=True)
