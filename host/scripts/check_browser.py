"""Verify the real Web UI with an explicitly labelled loopback mock source."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / "src"))
os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", str(HOST / "build/environment/browsers"))
from pango_video.web_server import instance_identity


def main():
    """Exercise rendering, original evidence, record replay and clean stopping."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    parser.add_argument("--out", type=Path, default=HOST / "reports" / ("environment_" + datetime.now().strftime("%Y%m%d")))
    parser.add_argument("--headed", action="store_true")
    parser.add_argument("--no-sandbox", action="store_true", help="only for restricted test runners")
    args = parser.parse_args()
    address = urlsplit(args.url)
    if address.scheme != "http" or address.hostname != "127.0.0.1":
        parser.error("Only the local loopback HTTP workbench can be tested")
    args.out.mkdir(parents=True, exist_ok=True)
    report = dict(utc=datetime.now(timezone.utc).isoformat(), source_mode="mock",
                  hardware_acceptance="not_performed", passed=False, checks=[],
                  headed=args.headed, chromium_sandbox=not args.no_sandbox)
    errors = []
    # Browser dependencies are optional for normal host operation, but installed
    # into the prepared environment so this check is repeatable on this machine.
    from playwright.sync_api import expect, sync_playwright
    with sync_playwright() as automation:
        browser = automation.chromium.launch(headless=not args.headed,
                                             chromium_sandbox=not args.no_sandbox)
        report["browser_version"] = browser.version
        page = browser.new_page(viewport={"width": 1600, "height": 1100})
        page.on("pageerror", lambda error: errors.append(str(error)))
        started = False
        try:
            response = page.goto(args.url, wait_until="networkidle")
            assert response.status == 200
            assert page.request.get(args.url + "/api/health").json() == instance_identity()
            expect(page.locator("#server-health")).to_have_text("服务已连接")
            status = page.request.get(args.url + "/api/status").json()
            assert status["state"] in ("idle", "stopped") and not status["running"]
            assert status["config"]["source_mode"] == "mock"
            report["checks"].append("HTTP page and initial inactive state")
            page.screenshot(path=str(args.out / "browser-idle.png"), full_page=True)

            page.locator("#start").click()
            started = True
            expect(page.locator("#live-canvas")).to_be_visible(timeout=30000)
            # Poll metrics through HTTP instead of page-level eval, which the
            # application's Content Security Policy deliberately prohibits.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                current = page.request.get(args.url + "/api/status").json()
                if current["metrics"]["assembly"]["counters"].get("live_frames_complete", 0) >= 20:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("The browser mock did not receive 20 complete frames")
            # A nonempty canvas proves that the real Worker converted the RAW
            # payload, rather than merely displaying a ready HTTP endpoint.
            visible = page.locator("#live-canvas").evaluate("canvas => ({width:canvas.width,height:canvas.height, pixels:[...canvas.getContext('2d').getImageData(0,0,2,2).data]})")
            assert visible["width"] > 0 and any(visible["pixels"])
            report["rendered_canvas"] = visible
            report["checks"].append("1920x1080 RAW8 loopback and browser Worker preview")
            page.screenshot(path=str(args.out / "browser-live.png"), full_page=True)
            page.locator("#save-current").click()
            expect(page.locator("#saved-total")).to_have_text(re.compile(r"^1 "), timeout=10000)
            archives = page.request.get(args.url + "/api/archives").json()["items"]
            status = page.request.get(args.url + "/api/status").json()
            item = next(item for item in archives if item["run_id"] == status["run_id"])
            raw = page.request.get(args.url + "/api/archive/pixels", params={"key": item["key"]}).body()
            metadata = page.request.get(args.url + "/api/archive/metadata", params={"key": item["key"]}).json()
            assert len(raw) == 1920 * 1080
            assert metadata["source_mode"] == "mock"
            assert metadata["sha256"] == hashlib.sha256(raw).hexdigest()
            report["raw_artifact"] = item["key"]
            report["raw_sha256"] = metadata["sha256"]
            report["checks"].append("manual RAW archive and original-byte SHA-256")

            page.locator("#stop").click()
            expect(page.locator("#start")).to_be_enabled()
            expect(page.locator("#stop")).to_be_disabled()
            final = page.request.get(args.url + "/api/status").json()
            assert final["state"] == "stopped" and not final["running"]
            started = False
            report["complete_frames"] = final["metrics"]["assembly"]["counters"].get("live_frames_complete", 0)
            report["run_id"] = final["run_id"]
            report["checks"].append("stop drains capture and preserves evidence")
            page.locator("nav [data-view='records']").click()
            page.locator("#archive-table").wait_for()
            expect(page.locator("#archive-table button").first).to_be_visible()
            page.locator("nav [data-view='settings']").click()
            page.locator("#cfg-device").wait_for(state="visible")
            report["checks"].append("record and connection settings navigation")
            assert not errors, errors
            report["passed"] = True
        except Exception as error:
            report["error"] = str(error)
            page.screenshot(path=str(args.out / "browser-failure.png"), full_page=True)
        finally:
            # Only stop the mock created by this check; user sessions were
            # rejected above. Close the test browser while leaving HTTP ready.
            if started:
                try:
                    token = page.request.get(args.url + "/api/session").json()["token"]
                    page.request.post(args.url + "/api/stop", data={}, headers={"X-Pango-Token": token})
                except Exception as error:
                    report["cleanup_error"] = str(error)
            report["page_errors"] = errors
            browser.close()
    (args.out / "browser-tests.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
