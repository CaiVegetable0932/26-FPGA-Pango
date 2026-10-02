"""Report this machine's host dependencies and attached hardware without opening devices."""
import argparse
from datetime import datetime, timezone
import getpass
import grp
import hashlib
from importlib import metadata
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys

sys.dont_write_bytecode = True
HOST = Path(__file__).resolve().parents[1]
ENVIRONMENT = HOST / "build/environment"


def command(args):
    """Keep tool errors as evidence, and cap probes so detached devices cannot hang."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        return dict(returncode=result.returncode, stdout=result.stdout.strip(), stderr=result.stderr.strip())
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(returncode=None, error=str(error))


def main():
    """Check software separately from USB/link presence and hardware acceptance."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=HOST / "reports" / ("environment_" + datetime.now().strftime("%Y%m%d")) / "environment.json")
    args = parser.parse_args()
    report = dict(utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
                  machine=platform.machine(), python=sys.version, executable=sys.executable,
                  hardware_acceptance="not_performed", checks={}, tools={}, packages={})
    report["checks"]["python_312_or_newer"] = sys.version_info >= (3, 12)
    # These modules cover TLS downloads, compressed artifacts, database support
    # and virtual environments, beyond the application's standard-library core.
    for name in ("ssl", "sqlite3", "bz2", "lzma", "venv"):
        try:
            __import__(name)
            report["checks"]["module_" + name] = True
        except ImportError:
            report["checks"]["module_" + name] = False
    for name in ("pyserial", "playwright"):
        try:
            report["packages"][name] = metadata.version(name)
            report["checks"]["package_" + name] = True
        except metadata.PackageNotFoundError:
            report["checks"]["package_" + name] = False
    tools = {"node": [str(ENVIRONMENT / "node/bin/node"), "--version"],
             "ffmpeg": [str(ENVIRONMENT / "bin/ffmpeg"), "-version"],
             "ffprobe": [str(ENVIRONMENT / "bin/ffprobe"), "-version"],
             "v4l2-ctl": [str(ENVIRONMENT / "bin/v4l2-ctl"), "--version"],
             "chromium": ["sh", str(HOST / "scripts/open_browser.sh"), "--version"]}
    for name, invocation in tools.items():
        result = command(invocation)
        report["tools"][name] = result
        report["checks"]["tool_" + name] = result["returncode"] == 0
    report["packages"]["pip"] = metadata.version("pip")
    report["installed_dependencies"] = (HOST / "config/environment-linux-arm64.lock.txt").read_text().splitlines()
    report["hardware_inventory"] = {"usb": command(["lsusb"]), "network": command(["ip", "-brief", "address"]),
                                    "video_nodes": sorted(str(path) for path in Path("/dev").glob("video*"))}
    import serial.tools.list_ports
    report["hardware_inventory"]["serial_ports"] = [dict(device=port.device, description=port.description,
                                                          vid=port.vid, pid=port.pid, serial_number=port.serial_number)
                                                       for port in serial.tools.list_ports.comports()]
    group = grp.getgrnam("dialout")
    report["dialout"] = dict(user=getpass.getuser(), configured=getpass.getuser() in group.gr_mem,
                             active_in_this_session=group.gr_gid in os.getgroups())
    report["udp_buffer_limit"] = command(["sysctl", "net.core.rmem_max", "net.core.rmem_default"])
    # Record Linux's actual SO_RCVBUF accounting result rather than assuming
    # equality with the requested application buffer means success.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8388608)
        report["udp_receive_buffer"] = dict(requested=8388608,
                                            reported=probe.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF))
    report["checks"]["udp_8mib_request_available"] = report["udp_receive_buffer"]["reported"] >= 8388608
    report["checks"]["dialout_configured"] = report["dialout"]["configured"]
    # Hash installation provenance and launchers, avoiding large mutable browser
    # profiles; package/browser versions remain separately visible in the report.
    report["source_sha256"] = {str(path.relative_to(HOST)): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in (HOST / "scripts/start_web.sh", HOST / "scripts/env.sh",
                                            HOST / "scripts/open_browser.sh", HOST / "scripts/run_capture_tool.sh",
                                            ENVIRONMENT / "downloads/node-SHASUMS256.txt")}
    report["software_environment_ready"] = all(report["checks"].values())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(software_environment_ready=report["software_environment_ready"],
                         checks=report["checks"], dialout=report["dialout"],
                         udp_receive_buffer=report["udp_receive_buffer"], report=str(args.report)),
                     ensure_ascii=False, indent=2))
    return 0 if report["software_environment_ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
