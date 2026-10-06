"""Enable or revert the verified Hagibis workaround for this boot only.

Do not install modules or alter JetPack/power settings. Reboot loads the original
system driver; explicit disable restores it while the capture card is unused.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import pwd
import subprocess

from trial_hagibis_uvc_payload import CANDIDATE, CANDIDATE_SHA, HOST, INSTALLED, ORIGINAL_SHA, preflight, sha


def main():
    """Apply only the reviewed module and preserve all original runtime parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable"))
    args = parser.parse_args()
    # depmod now selects the persistent override, so this earlier temporary
    # helper cannot promise that modprobe will revert to the vendor module.
    if Path("/usr/local/share/pango-hagibis/manifest.json").exists():
        raise RuntimeError("Persistent strategy is installed; use install_hagibis_strategy.py uninstall before temporary enable/disable")
    if os.geteuid() != 0:
        raise RuntimeError("Administrator approval required for UVC module changes")
    if args.action == "enable":
        report = preflight()
    else:
        # Reversion may only remove this exact candidate when no capture client
        # owns it. Validate the installed original before using modprobe.
        if sha(INSTALLED) != ORIGINAL_SHA or sha(CANDIDATE) != CANDIDATE_SHA:
            raise RuntimeError("Reviewed module files changed")
        if Path("/sys/module/uvcvideo/srcversion").read_text().strip() != "07CEFA74AE992273053776F":
            raise RuntimeError("The reviewed Hagibis module is not currently loaded")
        if int(Path("/sys/module/uvcvideo/refcnt").read_text()) != 0:
            raise RuntimeError("Close HDMI previews before reverting; driver is busy")
        bound = [path.name for path in Path("/sys/bus/usb/drivers/uvcvideo").glob("*:*") if path.is_symlink()]
        if any(not name.startswith("1-2.4:") for name in bound):
            raise RuntimeError("Additional UVC device present; refusing to interrupt it")
        report = dict(original_parameters={path.name: path.read_text().strip()
                                          for path in Path("/sys/module/uvcvideo/parameters").iterdir()})
    params = [name + "=" + value for name, value in report["original_parameters"].items()]
    subprocess.run(["rmmod", "uvcvideo"], check=True, timeout=15)
    try:
        if args.action == "enable":
            subprocess.run(["insmod", str(CANDIDATE), *params], check=True, timeout=15)
        else:
            subprocess.run(["modprobe", "uvcvideo", *params], check=True, timeout=15)
    except Exception:
        # Failure leaves the original system driver available rather than an
        # unbound device; do not force an unload if another client races us.
        if not Path("/sys/module/uvcvideo").exists():
            subprocess.run(["modprobe", "uvcvideo", *params], check=True, timeout=15)
        raise
    report.update(action=args.action, utc=datetime.now(timezone.utc).isoformat(),
                  loaded_version=Path("/sys/module/uvcvideo/version").read_text().strip(),
                  loaded_srcversion=Path("/sys/module/uvcvideo/srcversion").read_text().strip(),
                  installed_module_replaced=False, persists_after_reboot=False)
    folder = HOST / "reports/hardware_inputs_20261003"
    path = folder / ("uvc-payload-" + args.action + "-" + datetime.now(timezone.utc).strftime("%H%M%S%f") + ".json")
    path.write_text(json.dumps(report, indent=2) + "\n")
    owner = pwd.getpwnam("cai")
    os.chown(path, owner.pw_uid, owner.pw_gid)
    print(json.dumps(dict(report=str(path), version=report["loaded_version"], persistent=False)))


if __name__ == "__main__":
    main()
