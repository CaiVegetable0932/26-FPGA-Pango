"""Start the installed background workbench and reuse its browser tab."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / "src"))
from pango_video.web_launcher import is_same_instance


def main():
    """Use the saved hardware setup and normal user service, without sudo."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-browser", action="store_true", help="仅启动后台服务，不打开页面")
    parser.add_argument("--timeout", type=int, default=90, help="等待服务就绪的秒数，默认 90")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error("--timeout must be between 1 and 300 seconds")
    # systemctl start is idempotent. Reuse an already running local checkout
    # even if it was started manually, rather than create another receiver.
    if not is_same_instance(8765):
        result = subprocess.run(["systemctl", "--user", "start", "pango-host.service"],
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError("后台服务启动失败：" + result.stderr.strip())
    deadline = time.monotonic() + args.timeout
    while not is_same_instance(8765):
        if time.monotonic() >= deadline:
            raise RuntimeError("服务未就绪，请查看 journalctl --user -u pango-host -n 40 --no-pager")
        time.sleep(0.5)
    print("[Pango] Web 服务已就绪：http://127.0.0.1:8765/", flush=True)
    print("[Pango] 使用已保存的板卡参数；FPGA 较晚上电时请点击“启动 / 重连板卡链路”。", flush=True)
    if not args.no_browser:
        return subprocess.run(["/usr/bin/sh", str(HOST / "scripts/open_browser.sh"),
                               "http://127.0.0.1:8765/"], timeout=90).returncode
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[Pango] {error}", file=sys.stderr)
        raise SystemExit(1)
