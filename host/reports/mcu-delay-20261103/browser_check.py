"""Exercise full UI dispatch timing while intercepting every hardware mutation."""
import json
from pathlib import Path
import shutil
import time
from playwright.sync_api import sync_playwright

REPORT=Path(__file__).resolve().parent
state={'connected':True,'angles':{'pitch':0,'yaw':0},'age_ms':10,
       'state':{'motion_state':0,'fault_code':0,'xyz_normalized_micro':[0,0,0]}}
requests=[];errors=[]
with sync_playwright() as p:
    browser=p.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
    try:
        page=browser.new_page(viewport={'width':1440,'height':1080})
        page.on('pageerror',lambda error:errors.append(str(error)))
        def route_api(route):
            request=route.request
            if request.url.endswith('/api/mcu/status'):
                return route.fulfill(status=200,content_type='application/json',body=json.dumps(state))
            if request.method=='POST':
                # Never forward a test click to any physical device endpoint.
                requests.append({'route':request.url.split('8765')[-1], 'at':time.monotonic(), 'data':request.post_data_json})
                return route.fulfill(status=200 if '/api/mcu/' in request.url else 409,
                    content_type='application/json',body=json.dumps(state if '/api/mcu/' in request.url else {'error':'test blocks all hardware writes'}))
            route.continue_()
        page.route('**/api/**',route_api)
        page.goto('http://127.0.0.1:8765/',wait_until='domcontentloaded')
        page.wait_for_function("!document.querySelector('[data-mcu=gantry]').disabled")
        assert page.evaluate("document.querySelector('#recording-title')===null")
        assert page.evaluate("document.querySelector('#host-cpu-value')!==null")
        page.evaluate("() => {document.querySelector('#mcu-x').value='25';document.querySelector('#mcu-rpm').value='10';}")
        begin=time.monotonic();page.evaluate("document.querySelector('[data-mcu=gantry]').click()")
        page.wait_for_timeout(1000.0)
        assert not any(r['route']=='/api/mcu/gantry' for r in requests)
        countdown=page.evaluate("document.querySelector('#mcu-dispatch-status').textContent")
        page.evaluate("document.querySelector('#mcu-x').value='70'")
        deadline=time.monotonic()+5
        while not any(r['route']=='/api/mcu/gantry' for r in requests) and time.monotonic()<deadline:page.wait_for_timeout(50.0)
        gantry=next(r for r in requests if r['route']=='/api/mcu/gantry')
        assert 2.99<=gantry['at']-begin<4.5,gantry['at']-begin
        assert gantry['data']['x']==25
        page.wait_for_timeout(100.0)
        page.evaluate("() => {document.querySelector('#mcu-pitch').value='6';document.querySelector('#mcu-yaw').value='6';}")
        begin_move=time.monotonic();page.evaluate("document.querySelector('[data-mcu=move]').click()")
        deadline=time.monotonic()+5
        while not any(r['route']=='/api/mcu/move' for r in requests) and time.monotonic()<deadline:page.wait_for_timeout(50.0)
        move=next(r for r in requests if r['route']=='/api/mcu/move')
        assert 2.99<=move['at']-begin_move<4.5
        page.wait_for_timeout(100.0)
        # Emergency stop is immediate and prevents the pending target from firing.
        page.evaluate("document.querySelector('[data-mcu=gantry]').click()")
        page.wait_for_timeout(500.0);stop_time=time.monotonic()
        page.evaluate("document.querySelector('[data-mcu=stop]').click()")
        page.wait_for_timeout(300.0)
        stop=next(r for r in requests if r['route']=='/api/mcu/stop')
        assert stop['at']-stop_time<.5
        page.wait_for_timeout(3000.0)
        assert len([r for r in requests if r['route']=='/api/mcu/gantry'])==1
        page.evaluate("document.querySelector('[data-mcu=gantry]').click()")
        page.wait_for_timeout(200.0);page.evaluate("document.querySelector('#mcu-cancel-send').click()")
        page.wait_for_timeout(3100.0)
        assert len([r for r in requests if r['route']=='/api/mcu/gantry'])==1
        # Reload cancels, rather than resuming or firing a stale pending motion.
        page.evaluate("document.querySelector('[data-mcu=gantry]').click()")
        page.reload(wait_until='domcontentloaded');page.wait_for_timeout(3200.0)
        assert len([r for r in requests if r['route']=='/api/mcu/gantry'])==1
        assert not errors,errors
        result={'gantry_delay_seconds':gantry['at']-begin,'gimbal_delay_seconds':move['at']-begin_move,
                'stop_delay_seconds':stop['at']-stop_time,'countdown':countdown,
                'snapshot_preserved':True,'cancel_and_reload_prevent_send':True,'recording_removed':True,
                'cpu_retained':True,'page_errors':errors,'scope':'all POST requests intercepted; no physical commands'}
        (REPORT/'browser-check.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(result,ensure_ascii=False),flush=True)
        page.locator('[aria-labelledby="mcu-title"]').screenshot(path=str(REPORT/'mcu-panel.png'),timeout=15000)
    finally:browser.close()
