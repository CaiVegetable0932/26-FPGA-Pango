"""Cross-platform startup, instance reuse and graceful shutdown for the Web UI."""
import argparse
import http.client
import json
import os
import signal
import sys
import threading
import time
import webbrowser

from .web_server import LocalServer, instance_identity
from .web_session import SessionError


def is_same_instance(port, timeout=1.0):
    """Probe only loopback: no proxy, redirects, session token or capture mutation."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("GET", "/api/health")
        response = connection.getresponse()
        if response.status != 200:
            return False
        body = response.read(4097)
        return len(body) <= 4096 and json.loads(body) == instance_identity()
    except (OSError, http.client.HTTPException, ValueError):
        return False
    finally:
        connection.close()


def open_page(url):
    # Avoid launching a blocking text browser on SSH/headless Linux.
    if sys.platform.startswith("linux") and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        print("[Pango] No desktop session; open the URL above in a local browser.", flush=True)
        return
    try:
        opened = webbrowser.open(url, new=2)
    except Exception as error:
        print(f"[Pango] Browser could not be opened: {error}. Open the URL above manually.", flush=True)
        return
    if not opened:
        print("[Pango] Browser could not be opened. Open the URL above manually.", flush=True)


def open_when_ready(port, cancelled, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not cancelled.is_set() and time.monotonic() < deadline:
        if is_same_instance(port, timeout=0.5):
            if not cancelled.is_set():
                open_page(f"http://127.0.0.1:{port}/")
            return
        cancelled.wait(0.1)
    if not cancelled.is_set():
        print("[Pango] Browser startup timed out. Open the URL above after the service is ready.", flush=True)


def _interrupt(signum, frame):
    raise KeyboardInterrupt


def run(port=8765, *, open_browser=True):
    try:
        server = LocalServer(port)
    except (OSError, ValueError) as error:
        if port and is_same_instance(port):
            url = f"http://127.0.0.1:{port}/"
            print(f"[Pango] Already running from this checkout: {url}", flush=True)
            print("[Pango] Reusing the existing service and capture session.", flush=True)
            if open_browser:
                open_page(url)
            return 0
        print(f"[Pango] Could not start the local service: {error}", file=sys.stderr, flush=True)
        print("[Pango] If the port is occupied, use --port 8766 (or --port 0). "
              "An older Pango service must be stopped in its original terminal before restarting.",
              file=sys.stderr, flush=True)
        return 2

    cancelled = threading.Event()
    old_term = None
    exit_code = 0
    try:
        if threading.current_thread() is threading.main_thread():
            old_term = signal.signal(signal.SIGTERM, _interrupt)
        print(f"Pango Web UI: http://127.0.0.1:{server.server_port}/", flush=True)
        # Distinguish saved backend recovery from browser-owned HDMI capture.
        print(f"[Pango] Python {sys.version.split()[0]}; saved board recovery runs in the background; HDMI opens from the page.", flush=True)
        print("[Pango] Keep this terminal open. Press Ctrl+C here to stop the service safely.", flush=True)
        # LocalServer owns continuous, mutex-serialized startup/recovery.
        # It also handles host-first/board-later startup, not a one-shot probe.
        if open_browser:
            threading.Thread(target=open_when_ready, args=(server.server_port, cancelled),
                             name="pango-browser", daemon=True).start()
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        print("\n[Pango] Stopping capture and flushing pending records...", flush=True)
    except OSError as error:
        print(f"[Pango] Service error: {error}", file=sys.stderr, flush=True)
        exit_code = 2
    finally:
        cancelled.set()
        try:
            # Revoke auto writes before cancelling the owned startup/receiver.
            server.board_autoload.close()
            server.board_link.stop()
        except (OSError, SessionError) as error:
            print(f"[Pango] Capture could not stop cleanly: {error}", file=sys.stderr, flush=True)
            exit_code = 2
        finally:
            server.server_close()
            if old_term is not None:
                signal.signal(signal.SIGTERM, old_term)
    return exit_code


def main(argv=None):
    parser = argparse.ArgumentParser(description="Start or reopen the local Pango Web workbench.")
    parser.add_argument("--port", type=int, default=8765,
                        help="loopback HTTP port (default: 8765; 0 chooses a free port)")
    parser.add_argument("--no-browser", action="store_true",
                        help="run/reuse the service without opening a browser")
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("HTTP port must be between 0 and 65535")
    return run(args.port, open_browser=not args.no_browser)
