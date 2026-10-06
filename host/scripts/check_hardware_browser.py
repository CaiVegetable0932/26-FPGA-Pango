"""Verify real board/capture previews and save Hagibis selection in the user profile.

No fake camera or mock UDP source is used. Camera permission is granted only
to the loopback workbench in the diagnostic browser context.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / "scripts"))
from check_hardware_inputs import api, linux_hagibis, write_json


def main():
    """Exercise the actual browser's video track without changing board firmware."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--temporary-profile", action="store_true",
                        help="use an isolated project-local diagnostic profile while the user's browser is open")
    parser.add_argument("--keep-open", action="store_true", help="leave a successful headed preview visible until its window is closed")
    args = parser.parse_args()
    if args.keep_open and args.headless:
        parser.error("keep-open requires a visible browser window")
    os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", str(HOST / "build/environment/browsers"))
    from playwright.sync_api import expect, sync_playwright
    run = "hardware-browser-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    folder = HOST / "reports" / run
    folder.mkdir()
    report = dict(started_utc=datetime.now(timezone.utc).isoformat(), passed=False,
                  selected_physical_device=linux_hagibis(), hdmi_pairing_status="unverified",
                  isolated_profile=args.temporary_profile)
    errors = []
    with sync_playwright() as automation:
        # Daily-profile checks persist device selection for open_browser.sh.
        # An isolated diagnostic profile avoids locking or closing a user's
        # existing browser, and its settings remain separate from daily use.
        profile = HOST / "build/environment" / (run if args.temporary_profile else "browser-profile")
        context = automation.chromium.launch_persistent_context(
            str(profile), channel="chromium",
            headless=args.headless, chromium_sandbox=True,
            viewport={"width": 1600, "height": 1100})
        context.grant_permissions(["camera"], origin="http://127.0.0.1:8765")
        page = context.pages[0] if context.pages else context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        try:
            # Live RAW8 polling keeps connections active; DOM readiness and the
            # application's health indicator are the appropriate ready checks.
            page.goto("http://127.0.0.1:8765", wait_until="domcontentloaded")
            expect(page.locator("#server-health")).to_have_text("服务已连接")
            current = api("/api/status")
            if current["config"]["source_mode"] != "hardware_unverified":
                raise RuntimeError("Workbench must be receiving real board data")
            expect(page.locator("#live-canvas")).to_be_visible(timeout=15000)
            report["network_canvas"] = page.locator("#live-canvas").evaluate(
                "canvas => ({width:canvas.width,height:canvas.height})")
            page.locator("nav [data-view='settings']").click()
            # A persisted auto-resume can already own the same capture card.
            if page.locator("#capture-close").is_enabled():
                page.locator("#capture-close").click()
            page.locator("#capture-refresh").click()
            expect(page.locator("#capture-device option").filter(has_text="Hagibis").first).to_be_attached(timeout=15000)
            devices = page.locator("#capture-device").evaluate(
                "select => [...select.options].map(o=>({value:o.value,label:o.textContent}))")
            matches = [item for item in devices if "Hagibis" in item["label"] and item["value"]]
            if len(matches) != 1:
                raise RuntimeError(f"Expected exactly one browser Hagibis input; devices={devices}")
            page.locator("#capture-device").select_option(matches[0]["value"])
            page.locator("#capture-save").click()
            report["browser_device"] = matches[0]
            page.locator("#capture-open").click()
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                status = page.locator("#capture-settings-status").inner_text()
                if "接口已打开" in status or "操作失败" in status:
                    break
                page.wait_for_timeout(500)
            report["capture_status"] = status
            report["capture_message"] = page.locator("#capture-message").inner_text()
            page.locator("nav [data-view='live']").click()
            video = page.locator("#capture-video")
            # Opening a UVC track does not mean decoding has begun. Hagibis can
            # need several seconds after a resolution change; wait for actual
            # decoded frames before measuring playback progress.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                ready = video.evaluate("v => v.videoWidth > 0 && v.getVideoPlaybackQuality().totalVideoFrames > 0")
                if ready:
                    break
                page.wait_for_timeout(500)
            report["video"] = video.evaluate("video => ({width:video.videoWidth,height:video.videoHeight,"
                "readyState:video.readyState,currentTime:video.currentTime,"
                "quality:video.getVideoPlaybackQuality().totalVideoFrames,"
                "tracks:[...(video.srcObject?.getVideoTracks()||[])].map(t=>({label:t.label,settings:t.getSettings()}))})")
            page.wait_for_timeout(3000)
            report["video_after"] = video.evaluate("video => ({currentTime:video.currentTime,"
                "quality:video.getVideoPlaybackQuality().totalVideoFrames})")
            page.screenshot(path=str(folder / "dual-preview.png"), full_page=True)
            report["saved_device"] = page.evaluate("() => localStorage.getItem('pango.video-input.v1')")
            report["passed"] = (report["video"]["width"] > 0 and
                                report["video_after"]["quality"] > report["video"]["quality"] and not errors)
        except Exception as error:
            report["error"] = str(error)
            page.screenshot(path=str(folder / "failure.png"), full_page=True)
        finally:
            report["page_errors"] = errors
            # Retain the successful preview for direct user verification. This
            # affects only this diagnostic window, not existing desktop tabs.
            if args.keep_open and report["passed"]:
                write_json(folder / "browser.json", report)
                print(json.dumps(dict(event="PREVIEW_READY", report=str(folder / "browser.json"),
                                      url="http://127.0.0.1:8765/", video=report["video"]), ensure_ascii=False), flush=True)
                try:
                    while not page.is_closed():
                        page.wait_for_timeout(1000)
                except Exception:
                    # Closing the window tears down its automation connection.
                    pass
            context.close()
    write_json(folder / "browser.json", report)
    print(json.dumps(dict(report=str(folder / "browser.json"), passed=report["passed"],
                         error=report.get("error"), video=report.get("video"),
                         capture_message=report.get("capture_message")), ensure_ascii=False))
    return 0 if report["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
