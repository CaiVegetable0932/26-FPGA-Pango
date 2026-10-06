"""Open or focus one URL in the existing project Chromium, without reloading it."""
import argparse
import fcntl
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import urlsplit

ENVIRONMENT = Path(__file__).resolve().parents[1] / "build/environment"
PROFILE = ENVIRONMENT / "browser-profile"


def page_key(url):
    """Treat fragments and the root index alias as the same workbench tab."""
    value = urlsplit(url)
    path = value.path or "/"
    if value.hostname == "127.0.0.1" and path == "/index.html":
        path = "/"
    return value.scheme, value.hostname, value.port, path, value.query


def endpoint():
    """Validate Chromium's random loopback endpoint against its profile nonce."""
    connection = None
    try:
        port, path = (PROFILE / "DevToolsActivePort").read_text().splitlines()[:2]
        if not 0 < int(port) < 65536 or not path.startswith("/devtools/browser/"):
            return None
        connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=1)
        connection.request("GET", "/json/version")
        response = connection.getresponse()
        if response.status != 200:
            return None
        value = json.loads(response.read(8192))["webSocketDebuggerUrl"]
        expected = f"ws://127.0.0.1:{port}{path}"
        return expected if value == expected else None
    except (OSError, ValueError, KeyError, http.client.HTTPException):
        return None
    finally:
        if connection:
            connection.close()


def capture_rank(page):
    """Prefer the page owning live capture when removing existing duplicates."""
    try:
        return page.evaluate("""() => [
            [...document.querySelectorAll('video')].some(v =>
                v.srcObject?.getVideoTracks().some(t => t.readyState === 'live')),
            document.visibilityState === 'visible']""")
    except Exception:
        return [False, False]


def open_tab(browser, url):
    """Keep capture and calibration state; close only duplicate target URLs."""
    context = browser.contexts[0]
    matches = [p for p in context.pages if page_key(p.url) == page_key(url)]
    if matches:
        page = max(matches, key=capture_rank)
        for duplicate in matches:
            if duplicate != page:
                duplicate.close()
        action = "reused"
    else:
        page = next((p for p in context.pages if p.url == "about:blank"), None)
        page = page or context.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=30000)
        action = "opened"
    page.bring_to_front()
    return action


def main():
    """Serialize simultaneous login/manual opens; leave Chromium alive on exit."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", required=True, type=Path)
    parser.add_argument("url")
    args = parser.parse_args()
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        print(f"[Pango] 无桌面会话，请手动访问 {args.url}")
        return 0
    from playwright.sync_api import sync_playwright
    PROFILE.mkdir(parents=True, exist_ok=True)
    with (PROFILE / ".pango-open.lock").open("a") as lock:
        deadline = time.monotonic() + 45
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("浏览器打开操作超时，请稍后重试。")
                time.sleep(0.1)
        address = endpoint()
        if not address:
            # An older browser has no endpoint. Never kill it or open another
            # tab blindly; ask for one normal close before using the new entry.
            singleton = PROFILE / "SingletonLock"
            if singleton.is_symlink():
                try:
                    pid = int(os.readlink(singleton).rsplit("-", 1)[1])
                    os.kill(pid, 0)
                except (ProcessLookupError, ValueError):
                    pass
                else:
                    raise RuntimeError("旧工作台浏览器仍在运行，请关闭它后重新执行此命令。")
            flags = [str(args.chrome.resolve()), f"--user-data-dir={PROFILE}",
                     "--no-first-run", "--no-default-browser-check",
                     "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0"]
            if os.environ.get("PANGO_BROWSER_TEST_NO_SANDBOX") == "1":
                flags.append("--no-sandbox")
            # Only loopback is exposed. Keep permissions in the existing
            # profile, and detach the browser from the invoking terminal.
            with (ENVIRONMENT / "browser-launch.log").open("a") as output:
                child = subprocess.Popen([*flags, "about:blank"], stdin=subprocess.DEVNULL,
                    stdout=output, stderr=output, start_new_session=True)
            deadline = time.monotonic() + 30
            while not address and time.monotonic() < deadline:
                if child.poll() is not None:
                    raise RuntimeError("浏览器启动失败，查看 host/build/environment/browser-launch.log。")
                time.sleep(0.2)
                address = endpoint()
            if not address:
                raise RuntimeError("浏览器启动超时，未取得本机控制接口。")
        # no_defaults avoids changing a user's downloads/media/focus settings.
        # Stopping the Playwright client detaches; never call browser.close().
        with sync_playwright() as automation:
            browser = automation.chromium.connect_over_cdp(address, timeout=10000, no_defaults=True)
            action = open_tab(browser, args.url)
        print(f"[Pango] Browser tab {action}: {args.url}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[Pango] {error}", file=sys.stderr)
        raise SystemExit(1)
