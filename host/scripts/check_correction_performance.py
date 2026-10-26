"""Measure correction in the existing real workbench, retaining its video track."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from check_live_pixel_markers import snapshot, sample_window
from open_browser import endpoint, page_key
from playwright.sync_api import expect, sync_playwright


def main():
    """Record hardware/GL identity and actual draw progress without pixel readback."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=8)
    parser.add_argument("--profile", action="store_true", help="temporarily time GL upload/draw calls")
    args = parser.parse_args()
    report = {"utc": datetime.now(timezone.utc).isoformat()}
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(), no_defaults=True)
        page = next(p for c in browser.contexts for p in c.pages
                    if page_key(p.url) == page_key("http://127.0.0.1:8765/"))
        page.bring_to_front()
        page.locator("nav [data-view='live']").click()
        expect(page.locator("#capture-correction-toggle")).to_be_enabled()
        if page.locator("#capture-correction-toggle").get_attribute("aria-pressed") != "true":
            page.locator("#capture-correction-toggle").click()
        expect(page.locator("#capture-corrected")).to_be_visible()
        page.wait_for_timeout(1000)
        session = browser.new_browser_cdp_session()
        report["system"] = session.send("SystemInfo.getInfo")
        session.detach()
        # Query the already-created WebGL context; no extra renderer or camera.
        report["gl"] = page.evaluate("""() => {
            const canvas=document.getElementById('capture-corrected'),gl=canvas.getContext('webgl');
            if(!gl)return {renderer:'CPU'};
            const debug=gl.getExtension('WEBGL_debug_renderer_info');
            return {renderer:debug?gl.getParameter(debug.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER),
                vendor:debug?gl.getParameter(debug.UNMASKED_VENDOR_WEBGL):gl.getParameter(gl.VENDOR),
                attributes:gl.getContextAttributes(),extensions:gl.getSupportedExtensions(),
                dimensions:[canvas.width,canvas.height],implementation:canvas.dataset.renderer};
        }""")
        # Optional transparent wrappers separate driver/upload blocking from
        # shader submission; restore methods even when measurement fails.
        if args.profile:
            page.evaluate("""() => {
                const gl=document.getElementById('capture-corrected').getContext('webgl');
                window.__pangoGLProfile={gl,originals:{},stats:{}};
                for(const name of ['texImage2D','texSubImage2D','drawArrays']){
                    const original=gl[name],s={count:0,totalMs:0,maxMs:0};
                    __pangoGLProfile.originals[name]=original;__pangoGLProfile.stats[name]=s;
                    gl[name]=function(...args){const start=performance.now();try{return original.apply(this,args);}
                        finally{const ms=performance.now()-start;s.count++;s.totalMs+=ms;s.maxMs=Math.max(ms,s.maxMs);}};
                }
            }""")
        try:
            report["measurement"] = sample_window(page, args.seconds)
        finally:
            if args.profile:
                report["gl_calls"] = page.evaluate("""() => {
                    const p=window.__pangoGLProfile;for(const [name,fn] of Object.entries(p.originals))p.gl[name]=fn;
                    delete window.__pangoGLProfile;return p.stats;
                }""")
        report["stable_corrected_mode"] = all(s["browser"]["corrected"]["visible"]
                                                 for s in report["measurement"]["samples"])
        report["final"] = snapshot(page)
        # Performance evidence is counters/metadata, never a claim of HDMI source identity.
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"renderer":report["gl"]["renderer"],
            "attributes":report["gl"].get("attributes"),"stable_corrected_mode":report["stable_corrected_mode"],
            "gl_calls":report.get("gl_calls"),
            "rates":{k:v for k,v in report["measurement"].items() if k!="samples"},
            "report":str(args.out)},ensure_ascii=False,indent=2))


if __name__ == "__main__":
    main()
