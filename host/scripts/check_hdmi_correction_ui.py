"""Offline HDMI toggle/UI and synthetic-image checks; never opens real media."""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import urlsplit

HOST = Path(__file__).resolve().parents[1]
os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", str(HOST / "build/environment/browsers"))


def main():
    """Serve intercepted local assets to an isolated browser, with media denied."""
    from playwright.sync_api import expect, sync_playwright

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pixel-markers", action="store_true", help="also verify synthetic source/mapped SVG overlays")
    parser.add_argument("--out", type=Path, default=HOST / "reports/hdmi-correction-ui-20261006")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = dict(passed=False, hardware_acceptance="not_performed",
                  real_video_stream_verification="not_performed", checks=[])
    errors, requests = [], []
    with sync_playwright() as automation:
        # A fresh headless profile is independent of the user's open workbench.
        # Every URL is fulfilled from disk below; no running service is visited.
        browser = automation.chromium.launch(headless=True, chromium_sandbox=True)
        context = browser.new_context(viewport=dict(width=1600, height=1100))
        context.add_init_script("""(() => {
            window.__mediaRequests=0;
            Object.defineProperty(navigator,'mediaDevices',{value:{
                getUserMedia(){window.__mediaRequests++;throw Error('Real media forbidden in offline check');},
                enumerateDevices:async()=>[],addEventListener(){},removeEventListener(){}}});
            // Static canvases exercise the RAF compatibility path. Disable real
            // video callbacks before constructing either UI/rate controller.
            for(const key of ['requestVideoFrameCallback','cancelVideoFrameCallback'])
                Object.defineProperty(HTMLVideoElement.prototype,key,{value:undefined,configurable:true});
            // Keep shared preferences when another isolated calibration tab opens.
            if(!localStorage.getItem('__pangoOfflineInitialized')){
              localStorage.clear();localStorage.setItem('__pangoOfflineInitialized','1');
              localStorage.setItem('pango.fisheye-preview.v1',JSON.stringify({
                schema:'pango.fisheye-preview.v1',parameters:{model:'fisheye_equidistant',
                reference_width:1920,reference_height:1080,fx:801,fy:788,cx:945,cy:553,
                k1:.121,k2:-.118,k3:0,k4:.036,output_fov_deg:121}}));
            }
        })();""")

        def asset(route):
            """Block network/API activity and replace automatic app startup."""
            name = urlsplit(route.request.url).path.lstrip("/") or "index.html"
            requests.append(name)
            if args.pixel_markers and name == "fixture.rgb":
                # Explicitly synthetic saved RGB sample for the calibration tab.
                rgb = bytes(channel for y in range(180) for x in range(320)
                            for channel in (x % 256, y, 240 if (x // 16 + y // 16) % 2 else 30))
                route.fulfill(content_type="application/octet-stream", body=rgb)
                return
            if args.pixel_markers and name == "calibration.js":
                route.fulfill(content_type="text/javascript", body="""
                    window.__offlineTuning=PangoFisheyeTuning.create({video:document.getElementById('video'),storage:localStorage});
                    window.addEventListener('pagehide',()=>window.__offlineTuning.destroy());
                """)
                return
            if name == "app.js":
                # A callable state fixture exercises the real UI adapter without
                # opening a track; normal media acquisition still throws above.
                fixture = """
                    const original=PangoVideoInput.createController;
                    PangoVideoInput.createController=options=>{
                        const controller=original(options);
                        window.__emitInputState=values=>options.onState({...controller.getState(),...values});
                        return controller;
                    };
                """ if args.pixel_markers else ""
                route.fulfill(content_type="text/javascript", body=fixture + """
                    window.__offlineUI=PangoVideoInputUI.create();
                    window.addEventListener('pagehide',()=>window.__offlineUI.destroy());
                """)
                return
            if "/" in name or not (HOST / "web" / name).is_file():
                errors.append("Unexpected offline URL: " + name)
                route.fulfill(status=404, body="Offline check forbids external/API requests")
                return
            kind = {".js": "text/javascript", ".css": "text/css", ".html": "text/html",
                    ".svg": "image/svg+xml"}.get(Path(name).suffix, "application/octet-stream")
            route.fulfill(content_type=kind, body=(HOST / "web" / name).read_bytes())

        context.route("**/*", asset)
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        try:
            page.goto("http://localhost:9918/", wait_until="networkidle")
            button = page.locator("#capture-correction-toggle")
            expect(button).to_have_text("计算机矫正")
            expect(button).to_have_attribute("aria-pressed", "false")
            expect(page.locator("#capture-preview-open")).to_be_disabled()
            page.screenshot(path=str(out / "original-ui.png"), full_page=True)
            button.click()
            expect(button).to_have_text("显示原图")
            expect(button).to_have_attribute("aria-pressed", "true")
            expect(page.locator("#capture-view-label")).to_contain_text("PC 软件参考")
            expect(page.locator("#capture-correction-info")).to_contain_text("标定页已保存参数")
            expect(page.locator("#capture-correction-info")).to_contain_text("121°")
            expect(page.locator("#capture-corrected")).to_be_hidden()
            expect(page.locator("#capture-preview-rate")).to_have_text("矫正显示 0.0 FPS")
            assert page.evaluate("window.__mediaRequests") == 0
            report["checks"].append("Disconnected input toggle, accessible state, saved parameters and zero media requests")
            page.screenshot(path=str(out / "corrected-waiting-ui.png"), full_page=True)
            button.click()
            expect(page.locator("#capture-view-label")).to_contain_text("HDMI 原图")

            # This is a static coloured pattern on a canvas, not a MediaStream,
            # video playback, camera simulation or connection to real hardware.
            report["synthetic_comparison"] = page.evaluate("""() => {
                const math=PangoFisheyePreview,parameters=math.loadSettings(localStorage).parameters;
                const source=document.createElement('canvas');source.width=320;source.height=180;
                const ctx=source.getContext('2d',{willReadFrequently:true}),image=ctx.createImageData(320,180);
                for(let y=0;y<180;y++)for(let x=0;x<320;x++){
                    const i=4*(y*320+x);image.data[i]=x%256;image.data[i+1]=y;
                    image.data[i+2]=(Math.floor(x/16)+Math.floor(y/16))%2?240:30;image.data[i+3]=255;
                }
                ctx.putImageData(image,0,0);
                Object.assign(source,{videoWidth:320,videoHeight:180,readyState:2,paused:false,currentTime:0,
                    srcObject:{getVideoTracks:()=>[{readyState:'live',muted:false}]}});
                source.closest=()=>null;
                function pixels(canvas){const probe=document.createElement('canvas');
                    probe.width=canvas.width;probe.height=canvas.height;const c=probe.getContext('2d');
                    c.drawImage(canvas,0,0);return c.getImageData(0,0,probe.width,probe.height).data;}
                return ['webgl','cpu'].map(backend=>{
                    function canvas(){const c=document.createElement('canvas');
                        if(backend==='cpu'){const get=c.getContext.bind(c);
                            c.getContext=(type,...args)=>type==='webgl'?null:get(type,...args);}return c;}
                    const calibrated=canvas(),live=canvas(),reference=math.createRenderer(calibrated);
                    reference.render(source,parameters);
                    let frame,time=0,timer,rate;
                    const environment={performance:{now:()=>time},document,
                        requestAnimationFrame(fn){frame=fn;return 1;},cancelAnimationFrame(){frame=null;},
                        setInterval(fn){timer=fn;return 1;},clearInterval(){timer=null;},
                        addEventListener(){},removeEventListener(){}};
                    const view=PangoVideoInputUI.createCorrectionView({video:source,canvas:live,storage:localStorage,
                        environment,onRate:fps=>rate=fps});
                    view.setSource(true);view.toggle();frame();time=1000;timer();
                    const a=pixels(calibrated),b=pixels(live);
                    let different=0,nonblack=0;
                    for(let i=0;i<a.length;i++){if(a[i]!==b[i])different++;if(i%4!==3&&b[i])nonblack++;}
                    const result={requested_backend:backend,renderer:reference.kind,width:live.width,height:live.height,
                        different_bytes:different,nonblack_channels:nonblack,draw_count:Number(live.dataset.renderCount),fps:rate};
                    view.destroy();reference.dispose();return result;
                });
            }""")
            for case in report["synthetic_comparison"]:
                assert case["different_bytes"] == 0 and case["nonblack_channels"] > 1000, case
                assert case["draw_count"] == 1 and case["fps"] == 1, case
            report["checks"].append("Calibration and HDMI controller produce identical pixels from a static synthetic image, WebGL and CPU")

            # Independent CPU bilinear output catches stale texture contents,
            # uniforms, orientation or dimensions after cached GPU updates.
            report["texture_updates"] = page.evaluate("""() => {
                const math=PangoFisheyePreview,source=document.createElement('canvas'),gpu=document.createElement('canvas'),
                    cpu=document.createElement('canvas'),get=cpu.getContext.bind(cpu);
                cpu.getContext=(type,...args)=>type==='webgl'?null:get(type,...args);
                const gpuRenderer=math.createRenderer(gpu),cpuRenderer=math.createRenderer(cpu),results=[];
                const p=math.normalize(math.preset());
                function pixels(canvas){const probe=document.createElement('canvas');probe.width=canvas.width;probe.height=canvas.height;
                    const c=probe.getContext('2d');c.drawImage(canvas,0,0);return c.getImageData(0,0,probe.width,probe.height).data;}
                for(let frame=0;frame<4;frame++){
                    const w=frame===3?400:320,h=frame===3?225:180;source.width=w;source.height=h;
                    const c=source.getContext('2d'),im=c.createImageData(w,h);
                    for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=4*(y*w+x);
                        im.data[i]=frame%2?255-x*255/w:x*255/w;im.data[i+1]=y*255/h;im.data[i+2]=frame*60;im.data[i+3]=255;}
                    c.putImageData(im,0,0);
                    if(frame===2){p.fx=805;p.output_fov_deg=111;}
                    gpuRenderer.render(source,p);cpuRenderer.render(source,p);
                    const a=pixels(gpu),b=pixels(cpu);let n=0,sum=0,max=0;
                    for(let y=10;y<h-10;y+=9)for(let x=10;x<w-10;x+=11){
                        const [sx,sy]=math.sourcePoint(p,w,h,x,y);
                        if(sx<2||sy<2||sx>w-3||sy>h-3)continue;
                        for(let ch=0;ch<3;ch++){const d=Math.abs(a[4*(y*w+x)+ch]-b[4*(y*w+x)+ch]);n++;sum+=d;max=Math.max(max,d);}}
                    results.push({frame,width:w,height:h,channels:n,mean_difference:sum/n,max_difference:max});
                }
                gpuRenderer.dispose();cpuRenderer.dispose();return results;
            }""")
            assert all(case["channels"] > 500 and case["max_difference"] <= 2
                       for case in report["texture_updates"]), report["texture_updates"]
            report["checks"].append("Cached GPU texture updates, edited parameters and changed input sizes agree with independent CPU bilinear samples")

            # Validate wrapping without opening/refreshing the user's real page.
            page.set_viewport_size(dict(width=500, height=1100))
            button.click()
            bounds = page.locator(".hdmi-panel .viewer-footer").evaluate("""footer => {
                const r=footer.getBoundingClientRect();return [...footer.querySelectorAll('button')].map(b=>{
                    const q=b.getBoundingClientRect();return {inside:q.left>=r.left&&q.right<=r.right&&q.top>=r.top&&q.bottom<=r.bottom};});
            }""")
            assert all(item["inside"] for item in bounds), bounds
            assert page.evaluate("window.__mediaRequests") == 0
            assert not errors, errors
            report["checks"].append("Narrow viewport controls remain inside footer; real media requests remain zero")
            page.screenshot(path=str(out / "mobile-ui.png"), full_page=True)
            if args.pixel_markers:
                verify_pixel_markers(page, context, out, report, errors)
            assert not errors, errors
            report.update(passed=True, media_requests=0, browser_version=browser.version,
                          requests=requests, errors=errors)
        finally:
            report["errors"] = errors
            (out / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            context.close()
            browser.close()
    print(json.dumps(report, ensure_ascii=False, indent=2))


def verify_pixel_markers(page, context, out, report, errors):
    """Use static canvases and mocked input metadata, never a video stream."""
    from playwright.sync_api import expect

    page.set_viewport_size(dict(width=1600, height=1100))
    if page.locator("#capture-correction-toggle").get_attribute("aria-pressed") == "true":
        page.locator("#capture-correction-toggle").click()
    page.evaluate("""() => {
        const source=document.createElement('canvas');source.width=1920;source.height=1080;
        const c=source.getContext('2d');c.fillStyle='#183345';c.fillRect(0,0,1920,1080);
        c.strokeStyle='#c8deeb';c.lineWidth=2;
        for(let x=0;x<1920;x+=120){c.beginPath();c.moveTo(x,0);c.lineTo(x,1080);c.stroke();}
        for(let y=0;y<1080;y+=120){c.beginPath();c.moveTo(0,y);c.lineTo(1920,y);c.stroke();}
        c.strokeStyle='#749bab';c.beginPath();c.moveTo(0,0);c.lineTo(1920,1080);c.moveTo(1920,0);c.lineTo(0,1080);c.stroke();
        const raw=document.getElementById('live-canvas');raw.width=960;raw.height=540;
        raw.getContext('2d').drawImage(source,0,0,960,540);raw.hidden=false;
        document.getElementById('video-empty').hidden=true;
        window.__offlineUI.setNetworkFrame({width:960,height:540,sourceWidth:1920,sourceHeight:1080});
        const pattern=document.createElement('canvas');pattern.width=1920;pattern.height=1080;
        pattern.getContext('2d').drawImage(source,0,0);pattern.id='offline-static-pattern';
        document.getElementById('result-surface').append(pattern);
        const video=document.getElementById('capture-video');let fixtureSource={getVideoTracks:()=>[{readyState:'live',muted:false}]};
        Object.defineProperties(video,{srcObject:{get:()=>fixtureSource,set:value=>fixtureSource=value},
            videoWidth:{get:()=>1920},videoHeight:{get:()=>1080},readyState:{get:()=>2},paused:{get:()=>false},currentTime:{get:()=>0},
            // Static metadata never emits real video callbacks; use the legacy
            // scheduling fixture while all media entry points remain blocked.
            requestVideoFrameCallback:{value:undefined},cancelVideoFrameCallback:{value:undefined}});
        // The real correction renderer processes the static canvas. Only its
        // video-upload boundary is replaced; no HTML video playback is used.
        const createRenderer=PangoFisheyePreview.createRenderer;
        PangoFisheyePreview.createRenderer=canvas=>{
            const renderer=createRenderer(canvas);
            if(canvas.id!=='capture-corrected')return renderer;
            return {...renderer,render(input,p){renderer.render(source,p);}};
        };
        window.__emitInputState({stream_open:true,status:'open',pending:false,selected:{deviceId:'synthetic',label:'离线合成图片'},
            devices:[{deviceId:'synthetic',label:'离线合成图片'}],settings:{width:1920,height:1080,frameRate:30}});
        window.__rawBefore=[...raw.getContext('2d').getImageData(0,0,960,540).data];
    }""")
    toggle = page.locator("#pixel-markers-toggle")
    expect(toggle).to_have_text("显示像素标记")
    toggle.click()
    expect(page.locator("#raw-pixel-markers")).to_be_visible()
    expect(page.locator("#capture-pixel-markers")).to_be_visible()
    expect(page.locator("#raw-pixel-markers > g")).to_have_count(20)
    expect(page.locator("#capture-pixel-markers > g")).to_have_count(20)
    assert page.evaluate("""() => {
        const now=document.getElementById('live-canvas').getContext('2d').getImageData(0,0,960,540).data;
        return now.every((value,i)=>value===window.__rawBefore[i]);
    }""")
    page.screenshot(path=str(out / "original-pixel-markers.png"), full_page=True)
    page.locator("#capture-correction-toggle").click()
    expect(page.locator("#capture-corrected")).to_be_visible()
    page.wait_for_function("document.querySelector('#capture-pixel-markers').dataset.coordinates && document.querySelector('#pixel-markers-info').textContent.includes('矫正视野内')")
    mapped = page.locator("#capture-pixel-markers").evaluate("el=>JSON.parse(el.dataset.coordinates)")
    visible = [p for p in mapped if p["visible"]]
    assert 0 < len(visible) < 20
    assert any(abs(p["point"][0] - p["output"][0]) > 1 for p in visible)
    expect(page.locator("#capture-pixel-markers > g")).to_have_count(len(visible))
    expect(page.locator("#capture-pixel-markers > g circle").first).to_be_visible()
    expect(page.locator("#pixel-markers-info")).to_contain_text("视野外")
    page.screenshot(path=str(out / "mapped-pixel-markers.png"), full_page=True)
    report["marker_positions"] = mapped
    report["checks"].append("Real workbench controls: 20 original overlays per link, mapped/cropped IDs, source bytes unchanged")

    # Exercise the actual calibration tuning adapter using saved synthetic RGB.
    # The capture/calibration network startup script is replaced, so no API or
    # camera can be requested. Shared storage updates reach the workbench tab.
    calibration = context.new_page()
    calibration.on("pageerror", lambda error: errors.append(str(error)))
    calibration.goto("http://localhost:9918/calibration.html", wait_until="networkidle")
    calibration.evaluate("""() => window.__offlineTuning.setSamples(
        [{id:'fixture',name:'离线合成样本',width:320,height:180}],()=>'/fixture.rgb','offline-group')""")
    expect(calibration.locator("#tuning-original-markers > g")).to_have_count(20)
    expect(calibration.locator("#tuning-original-markers")).to_be_visible()
    expect(calibration.locator("#tuning-corrected-markers > g circle").first).to_be_visible()
    expect(calibration.locator("#tuning-pixel-markers-toggle")).to_have_text("隐藏像素标记")
    calibration.locator('input[name="output_fov_deg"]').fill("50")
    calibration.locator('input[name="output_fov_deg"]').dispatch_event("input")
    expect(page.locator("#capture-correction-info")).to_contain_text("50°")
    page.wait_for_function("JSON.parse(document.querySelector('#capture-pixel-markers').dataset.coordinates).filter(p=>p.visible).length<7")
    expect(calibration.locator("#tuning-marker-info")).to_contain_text("视野外")
    calibration.locator("#manual-preview").screenshot(path=str(out / "calibration-pixel-markers.png"))
    calibration.locator("#tuning-pixel-markers-toggle").click()
    expect(page.locator("#pixel-markers-toggle")).to_have_text("显示像素标记")
    expect(page.locator("#raw-pixel-markers")).to_be_hidden()
    expect(page.locator("#capture-pixel-markers")).to_be_hidden()
    assert calibration.evaluate("window.__mediaRequests") == 0 and page.evaluate("window.__mediaRequests") == 0
    report["checks"].append("Actual calibration adapter: saved synthetic RGB, shared visibility, updated FOV propagates mapped markers without real media")
    calibration.close()


if __name__ == "__main__":
    main()
