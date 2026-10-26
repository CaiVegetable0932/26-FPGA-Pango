"""Wait briefly for the saved board interface, then start the normal workbench.

Desktop login can occur before NetworkManager has assigned the direct-link IP.
Wait for existing configuration without altering IPs, FPGA state or firmware.
"""
import json
import os
from pathlib import Path
import subprocess
import time

HOST = Path(__file__).resolve().parents[1]


def main():
    """Use the persisted profile, including the existing cold/warm epoch safeguards."""
    profile = json.loads((HOST / "config/board-link.json").read_text())
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        result = subprocess.run(["ip", "-j", "address", "show", "dev", profile["interface"]],
                                capture_output=True, text=True, timeout=5)
        cards = json.loads(result.stdout or "[]") if result.returncode == 0 else []
        ipv4 = any(a.get("family") == "inet" for n in cards for a in n.get("addr_info", []))
        serial = Path("/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0")
        if ipv4 and serial.exists():
            break
        time.sleep(1)
    # Keep the page available even if hardware is absent; its existing controls
    # report the missing link and allow a later reconnect without another login.
    os.execv("/usr/bin/sh", ["/usr/bin/sh", str(HOST / "scripts/start_web.sh"), "--no-browser"])


if __name__ == "__main__":
    main()
