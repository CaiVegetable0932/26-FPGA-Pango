"""Startup checks use isolated loopback servers and temporary files under host/build."""
from contextlib import redirect_stderr, redirect_stdout
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from pango_video.cli import HOST_ROOT
from pango_video import web_launcher as launcher
from pango_video.web_server import LocalServer, instance_identity
from pango_video.web_session import SessionError, WebSession


def get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


class LauncherTests(unittest.TestCase):
    def setUp(self):
        # Background recovery must never read a developer's saved physical board
        # preferences during launcher tests. Copy only the mock receiver fixture.
        build = HOST_ROOT / "build"
        build.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="launcher-unit-", dir=build)
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "config").mkdir()
        shutil.copyfile(HOST_ROOT / "config/receiver.mock.json", root / "config/receiver.mock.json")
        self.server = LocalServer(0, WebSession(root))
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever,
            kwargs={"poll_interval":0.02}, daemon=True)
        self.thread.start()
        self.output = io.StringIO()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def test_health_identity_has_no_path_or_token(self):
        status, body = get(self.port, "/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), instance_identity())
        self.assertNotIn(self.server.token, body.decode())
        self.assertNotIn(str(HOST_ROOT), body.decode())
        self.assertTrue(launcher.is_same_instance(self.port))

    def test_reuse_preserves_service_and_capture(self):
        with patch.object(self.server.session, "stop") as stop, \
                patch.object(launcher, "open_page") as browser, redirect_stdout(self.output):
            self.assertEqual(launcher.run(self.port), 0)
            browser.assert_called_once_with(f"http://127.0.0.1:{self.port}/")
            stop.assert_not_called()
        self.assertIn("Already running", self.output.getvalue())
        self.assertEqual(get(self.port, "/api/status")[0], 200)

    def test_different_checkout_is_not_reused_or_opened(self):
        identity = dict(instance_identity(), workspace="another-checkout")
        with patch.object(launcher, "instance_identity", return_value=identity), \
                patch.object(launcher, "open_page") as browser, redirect_stderr(self.output):
            self.assertEqual(launcher.run(self.port), 2)
            browser.assert_not_called()
        self.assertIn("--port 8766", self.output.getvalue())
        self.assertEqual(get(self.port, "/api/status")[0], 200)

    def test_probe_rejects_foreign_http_and_does_not_follow_redirects(self):
        class ForeignHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(302 if self.server.redirect else 200)
                self.send_header("Location", "http://example.invalid/")
                self.end_headers()
                self.wfile.write(self.server.body)

        server = ThreadingHTTPServer(("127.0.0.1",0), ForeignHandler)
        server.redirect, server.body = False, b"not JSON"
        thread = threading.Thread(target=server.serve_forever,
            kwargs={"poll_interval":0.02}, daemon=True)
        thread.start()
        try:
            for redirect, body in [(False,b"not JSON"), (False,b"[]"),
                    (False,b" "*4097), (True,json.dumps(instance_identity()).encode())]:
                with self.subTest(redirect=redirect, size=len(body)):
                    server.redirect, server.body = redirect, body
                    self.assertFalse(launcher.is_same_instance(server.server_port))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_browser_waits_for_readiness_and_respects_cancellation(self):
        event = threading.Event()
        with patch.object(launcher, "open_page") as browser:
            launcher.open_when_ready(self.port, event)
            browser.assert_called_once_with(f"http://127.0.0.1:{self.port}/")
            event.set()
            launcher.open_when_ready(self.port, event)
            self.assertEqual(browser.call_count, 1)
        with patch.object(launcher, "is_same_instance", side_effect=[False, True]), \
                patch.object(launcher, "open_page") as browser:
            launcher.open_when_ready(self.port, threading.Event())
            browser.assert_called_once()

    def test_headless_linux_does_not_start_a_text_browser(self):
        with patch.object(sys, "platform", "linux"), \
                patch.dict(os.environ, {"DISPLAY":"", "WAYLAND_DISPLAY":""}), \
                patch.object(launcher.webbrowser, "open") as browser, redirect_stdout(self.output):
            launcher.open_page("http://127.0.0.1:8765/")
            browser.assert_not_called()
        self.assertIn("No desktop session", self.output.getvalue())

    def test_browser_failures_keep_manual_url_available(self):
        for kwargs in ({"return_value":False}, {"side_effect":OSError("no browser")}):
            with self.subTest(kwargs=kwargs), patch.object(sys,"platform","win32"), \
                    patch.object(launcher.webbrowser,"open",**kwargs), redirect_stdout(self.output):
                launcher.open_page("http://127.0.0.1:8765/")
        self.assertIn("manually", self.output.getvalue())

    def test_interrupt_drains_capture_and_closes_socket(self):
        previous = signal.getsignal(signal.SIGTERM)
        with patch.object(launcher, "LocalServer") as factory, redirect_stdout(self.output):
            server = factory.return_value
            server.serve_forever.side_effect = KeyboardInterrupt
            # Coordinator shutdown delegates to the owned receiver's stop.
            server.board_link.profile = {}
            server.board_link.stop.side_effect = server.session.stop
            self.assertEqual(launcher.run(0, open_browser=False), 0)
            server.session.stop.assert_called_once()
            server.server_close.assert_called_once()
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

    def test_failed_capture_stop_still_closes_socket_and_reports_failure(self):
        with patch.object(launcher,"LocalServer") as factory, \
                redirect_stdout(self.output), redirect_stderr(self.output):
            server = factory.return_value
            server.serve_forever.side_effect = KeyboardInterrupt
            server.session.stop.side_effect = SessionError("writer still busy")
            # Preserve the shutdown-failure assertion through the new owner.
            server.board_link.profile = {}
            server.board_link.stop.side_effect = server.session.stop
            self.assertEqual(launcher.run(0, open_browser=False), 2)
            server.server_close.assert_called_once()
        self.assertIn("writer still busy", self.output.getvalue())

    def test_invalid_port_does_not_create_a_server(self):
        for port in ("-1", "65536", "not-a-port"):
            with self.subTest(port=port), patch.object(launcher,"LocalServer") as factory, \
                    redirect_stderr(self.output), self.assertRaises(SystemExit) as error:
                launcher.main(["--port", port, "--no-browser"])
            self.assertEqual(error.exception.code, 2)
            factory.assert_not_called()


class LauncherEntryTests(unittest.TestCase):
    def test_relocated_entries_real_http_and_clean_exit(self):
        build = (HOST_ROOT / "build").resolve()
        build.mkdir(exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="launcher path 测试 ", dir=build)
        root = Path(temp.name).resolve()
        self.assertTrue(root.is_relative_to(build))
        child = None
        reader = None
        lines = []
        try:
            for folder in ("scripts", "src/pango_video", "config"):
                (root / folder).mkdir(parents=True, exist_ok=True)
            for name in ("web.py", "start_web.cmd", "start_web.sh"):
                shutil.copy2(HOST_ROOT / "scripts" / name, root / "scripts" / name)
            for source in (HOST_ROOT / "src/pango_video").glob("*.py"):
                shutil.copy2(source, root / "src/pango_video" / source.name)
            shutil.copy2(HOST_ROOT / "config/receiver.mock.json", root / "config/receiver.mock.json")
            shutil.copytree(HOST_ROOT / "web", root / "web")
            # Inject Ctrl+C through Python so the check also works without a Windows console.
            harness = ("import _thread, runpy, sys, threading; "
                "threading.Thread(target=lambda: (sys.stdin.readline(), _thread.interrupt_main()), daemon=True).start(); "
                "sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')")
            child = subprocess.Popen([sys.executable, "-X", "utf8", "-B", "-c", harness,
                str(root / "scripts/web.py"), "--port", "0", "--no-browser"], cwd=build,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8")
            output = queue.Queue()

            def collect():
                for line in child.stdout:
                    lines.append(line)
                    output.put(line)
                output.put(None)

            reader = threading.Thread(target=collect, daemon=True)
            reader.start()
            first = output.get(timeout=10)
            self.assertIsNotNone(first, "".join(lines))
            self.assertTrue(first.startswith("Pango Web UI: http://127.0.0.1:"), first)
            port = int(first.rsplit(":", 1)[1].strip().strip("/"))
            self.assertEqual(get(port, "/")[0], 200)
            status, body = get(port, "/api/status")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["state"], "idle")
            self.assertFalse(json.loads(body)["running"])
            result = subprocess.run([sys.executable, "-X", "utf8", "-B",
                str(root / "scripts/web.py"), "--port", str(port), "--no-browser"],
                cwd=build, capture_output=True, text=True, encoding="utf-8", timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Already running", result.stdout)

            if os.name == "nt":
                entry = root / "scripts/start_web.cmd"
                environment = dict(os.environ, PANGO_NO_PAUSE="1", PANGO_PYTHON=sys.executable)

                def batch(args, env):
                    command = subprocess.list2cmdline([str(entry), *args])
                    prefix = subprocess.list2cmdline([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/s", "/c"])
                    return subprocess.run(prefix + ' "' + command + '"', cwd=build, env=env,
                        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)

                result = batch(["--port", str(port), "--no-browser"], environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Already running", result.stdout)
                environment.pop("PANGO_PYTHON")
                result = batch(["--help"], environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("--no-browser", result.stdout)
                result = batch(["--port", "65536"], environment)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                environment["PANGO_PYTHON"] = str(root / "missing python.exe")
                result = batch([], environment)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Python 3.12 or newer was not found", result.stdout)

            shell = shutil.which("sh")
            if not shell and os.name == "nt" and shutil.which("git"):
                candidate = Path(shutil.which("git")).parent.parent / "bin/bash.exe"
                if candidate.is_file():
                    shell = str(candidate)
            if shell:
                entry = (root / "scripts/start_web.sh").as_posix()
                environment = dict(os.environ, PANGO_PYTHON=Path(sys.executable).as_posix())
                result = subprocess.run([shell, "-n", entry], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                result = subprocess.run([shell, entry, "--port", str(port), "--no-browser"],
                    cwd=build, env=environment, capture_output=True, text=True, encoding="utf-8", timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Already running", result.stdout)
                environment["PANGO_PYTHON"] = (root / "missing python").as_posix()
                result = subprocess.run([shell, entry], cwd=build, env=environment,
                    capture_output=True, text=True, encoding="utf-8", timeout=10)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Python 3.12 or newer is required", result.stderr)
            else:
                print("[launcher tests] No shell found; shell entry needs target-machine validation.")

            self.assertEqual(json.loads(get(port, "/api/status")[1])["state"], "idle")
            child.stdin.write("stop\n")
            child.stdin.flush()
            child.wait(timeout=10)
            reader.join(2)
            self.assertEqual(child.returncode, 0, "".join(lines))
            self.assertTrue(any("Stopping capture" in line for line in lines), "".join(lines))
            self.assertFalse(any("Traceback" in line for line in lines), "".join(lines))
        finally:
            if child is not None:
                if child.poll() is None:
                    try:
                        child.stdin.write("stop\n")
                        child.stdin.flush()
                        child.wait(timeout=10)
                    except (OSError, subprocess.TimeoutExpired):
                        child.kill()  # Only this test's child, never an existing workbench.
                        child.wait(timeout=5)
                if reader is not None:
                    reader.join(2)
                child.stdin.close()
                child.stdout.close()
            self.assertTrue(root.resolve().is_relative_to(build))
            temp.cleanup()
