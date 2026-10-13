"""Inspect or exercise the current real preview; restore mode, view and size."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--reopen", action="store_true", help="仅重建项目主预览标签页，保留标定页")
    parser.add_argument("--cycles", type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 20:
        parser.error("cycles must be 1..20")
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(),no_defaults=True)
        page = next(p for p in browser.contexts[0].pages if page_key(p.url)==page_key("http://127.0.0.1:8765/"))
        if args.reopen:
            # A stalled project tab owns only its preview, not board state.
            # Close that one target without a beforeunload prompt; keep others.
            context=page.context
            replacement=context.new_page()
            page.close(run_before_unload=False)
            page=replacement
            page.goto("http://127.0.0.1:8765/",wait_until="domcontentloaded",timeout=30000)
            page.bring_to_front()
            print("Canonical preview tab recreated; other tabs retained")
            return
        errors=[]
        page.on("pageerror",lambda error:errors.append(str(error)))
        if args.inspect:
            print(json.dumps(page.evaluate("() => ({diagnostics:window.pangoPreviewDiagnostics?.(),canvas:{...document.querySelector('#live-canvas').dataset},hdmi:document.querySelector('#capture-preview-rate').textContent})"),ensure_ascii=False))
            return
        saved=page.evaluate("() => ({mode:document.querySelector('[data-color].selected').dataset.color,width:document.querySelector('#video-surface').style.width,view:document.querySelector('nav .active').dataset.view})")
        checks=[];completed=False
        def wait_mode(mode):
            page.wait_for_function("mode => {const d=window.pangoPreviewDiagnostics?.();return d?.latest?.mode===mode&&d.latest_submission_age_ms<1000}",arg=mode,timeout=15000,polling=100)
            value=page.evaluate("() => window.pangoPreviewDiagnostics()")
            if value["queue"]["executing"]>1 or value["queue"]["pending"]>1:
                raise RuntimeError("Preview queue exceeded its bound")
            return value
        try:
            # Direct DOM activation avoids animation-frame selector polling
            # when the desktop compositor throttles the remote preview window.
            def click(selector):
                page.evaluate("selector=>document.querySelector(selector).click()",selector)
            click('nav button[data-view="live"]')
            for cycle in range(args.cycles):
                # Real mode/visibility/size changes test connection generation.
                # They do not touch board controls, sensor settings or archives.
                for mode in ("color","gray","raw"):
                    click(f'[data-color="{mode}"]')
                    checks.append(dict(cycle=cycle,kind="mode",mode=mode,diagnostics=wait_mode(mode)))
                click('nav button[data-view="settings"]')
                page.wait_for_timeout(100)
                click('nav button[data-view="live"]')
                checks.append(dict(cycle=cycle,kind="view_recovery",diagnostics=wait_mode("raw")))
                for width,expected in (("1920px",1920),("800px",960)):
                    page.evaluate("width=>{document.querySelector('#video-surface').style.width=width}",width)
                    page.wait_for_function("width => window.pangoPreviewDiagnostics?.().latest?.width===width",arg=expected,timeout=15000,polling=100)
                    value=wait_mode("raw")
                    if expected==1920 and not value["latest"]["directTexture"]:
                        raise RuntimeError("Native RAW did not use the direct single-channel GPU path")
                    checks.append(dict(cycle=cycle,kind="size",width=expected,diagnostics=value))
            if errors:
                raise RuntimeError("Browser errors: "+str(errors))
            completed=True
        finally:
            # Leave the user's canonical tab exactly in its former display mode.
            page.evaluate("width=>{document.querySelector('#video-surface').style.width=width}",saved["width"])
            click(f'[data-color="{saved["mode"]}"]')
            click(f'nav button[data-view="{saved["view"]}"]')
            folder=Path(__file__).resolve().parents[1]/"reports"/("preview-update-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
            folder.mkdir()
            (folder/"lifecycle.json").write_text(json.dumps(dict(passed=completed and not errors,
                requested_cycles=args.cycles,checks=checks,errors=errors,restored=saved,
                scope="mode_view_and_css_size_not_cold_boot_or_usb_reconnect"),ensure_ascii=False,indent=2)+"\n")
            print(f"Report: {folder}; checks: {len(checks)}; errors: {len(errors)}")


if __name__ == "__main__":
    main()
