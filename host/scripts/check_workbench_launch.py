"""Verify actual repeated/concurrent entry calls without restarting capture."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import http.client
import json
from pathlib import Path
import subprocess
import time

from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright

HOST = Path(__file__).resolve().parents[1]
URL = "http://127.0.0.1:8765/"


def snapshot():
    """Read service and page identity without copying session tokens or pixels."""
    connection = http.client.HTTPConnection("127.0.0.1", 8765, timeout=5)
    try:
        connection.request("GET", "/api/status")
        response = connection.getresponse()
        status = json.loads(response.read())
        assert response.status == 200
    finally:
        connection.close()
    pid = subprocess.check_output(["systemctl", "--user", "show", "pango-host",
                                   "-p", "MainPID", "--value"], text=True).strip()
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(), no_defaults=True, timeout=10000)
        pages = []
        for page in browser.contexts[0].pages:
            client = browser.contexts[0].new_cdp_session(page)
            target = client.send("Target.getTargetInfo")["targetInfo"]["targetId"]
            client.detach()
            pages.append(dict(url=page.url, target=target, title=page.title()))
    return dict(pid=pid, state=status["state"], running=status["running"],
                run_id=status.get("run_id"), pages=pages)


def launch(command):
    """Exercise the same shell entries the user and desktop execute."""
    started = time.monotonic()
    result = subprocess.run(command, cwd=HOST.parent, capture_output=True, text=True, timeout=100)
    return dict(command=command, code=result.returncode, stdout=result.stdout,
                stderr=result.stderr, seconds=round(time.monotonic() - started, 3))


def main():
    """Assert one stable workbench tab/service across both open entry points."""
    before = snapshot()
    calls = [launch(["sh", str(HOST / "scripts/start_workbench.sh")])]
    # Race two manual calls with the existing installed desktop-login helper.
    commands = [["sh", str(HOST / "scripts/start_workbench.sh")]] * 2 + [
        ["sh", "/usr/local/libexec/pango/open_workbench_at_login.sh"]]
    with ThreadPoolExecutor(max_workers=3) as executor:
        calls.extend(executor.map(launch, commands))
    after = snapshot()
    before_main = [p for p in before["pages"] if page_key(p["url"]) == page_key(URL)]
    after_main = [p for p in after["pages"] if page_key(p["url"]) == page_key(URL)]
    checks = dict(entries_succeeded=all(c["code"] == 0 for c in calls),
                  single_workbench=len(before_main) == len(after_main) == 1,
                  same_page=bool(before_main and after_main and before_main[0]["target"] == after_main[0]["target"]),
                  same_service=before["pid"] == after["pid"] and before["pid"] != "0",
                  same_capture=before["run_id"] == after["run_id"] and before["running"] == after["running"],
                  other_pages_preserved={p["target"] for p in before["pages"] if p not in before_main}
                      <= {p["target"] for p in after["pages"]})
    report = dict(utc=datetime.now(timezone.utc).isoformat(), before=before, after=after,
                  calls=calls, checks=checks, passed=all(checks.values()),
                  hardware_acceptance="not_performed", physical_reboot_test="not_performed")
    out = HOST / "reports/workbench-launch-20261004"
    out.mkdir(parents=True, exist_ok=True)
    (out / "launch-check.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
