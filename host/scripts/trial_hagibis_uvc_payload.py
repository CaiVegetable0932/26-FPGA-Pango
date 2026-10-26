"""Run a bounded, temporary Hagibis module trial and restore the original.

Never write /lib/modules or change power, clocks, firmware or JetPack packages.
Reject a busy driver or any other UVC device; never force module removal.
Capture subprocesses run as the normal desktop user, not as root.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import time

HOST = Path(__file__).resolve().parents[1]
BUILD = HOST / "build/uvc-diagnostic"
ORIGINAL = BUILD / "original-uvcvideo.ko"
CANDIDATE = BUILD / "hagibis-payload/uvcvideo.ko"
INSTALLED = Path("/lib/modules/5.15.148-tegra/kernel/drivers/media/usb/uvc/uvcvideo.ko")
ORIGINAL_SHA = "555d9945e8ac1f4a5f3b3eb5d0d8f7765b18dbaf8457b4fbd15b39947baa53eb"
CANDIDATE_SHA = "2ba0ffd9ed762064486430eb02a61172ffe244b02542f4a83531f4b24d8f0120"


def sha(path):
    """Check the exact reviewed module bytes immediately before use."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def preflight():
    """Fail closed on changed modules, mismatched identity, busy use or additional UVC devices."""
    # The prior trial's restoration assumes the original modprobe selection.
    # Once persistence is installed, use its dedicated verification/rollback.
    if Path("/usr/local/share/pango-hagibis/manifest.json").exists():
        raise RuntimeError("Persistent strategy installed; use install_hagibis_strategy.py verify-load instead")
    if os.uname().release != "5.15.148-tegra":
        raise RuntimeError("Unexpected kernel release")
    if sha(ORIGINAL) != ORIGINAL_SHA or sha(INSTALLED) != ORIGINAL_SHA or sha(CANDIDATE) != CANDIDATE_SHA:
        raise RuntimeError("Module SHA256 changed since review")
    checks = json.loads((BUILD / "payload-build-check.json").read_text())["checks"]
    if not all(checks.values()):
        raise RuntimeError("Build compatibility checks failed")
    if Path("/sys/module/uvcvideo/srcversion").read_text().strip() != "62141F80FEED8A5C0693267":
        raise RuntimeError("Unexpected currently loaded module")
    if int(Path("/sys/module/uvcvideo/refcnt").read_text()) != 0:
        raise RuntimeError("UVC driver is busy; refusing to interrupt capture")
    device = Path("/sys/bus/usb/devices/1-2.4")
    expected = dict(idVendor="1de1", idProduct="f105", product="Hagibis", serial="-602393270")
    actual = {key: (device / key).read_text().strip() for key in expected}
    if actual != expected:
        raise RuntimeError("Physical Hagibis identity changed")
    bound = [path.name for path in Path("/sys/bus/usb/drivers/uvcvideo").glob("*:*") if path.is_symlink()]
    if not bound or any(not name.startswith("1-2.4:") for name in bound):
        raise RuntimeError("Other UVC interfaces are present; refusing shared-driver changes")
    parameters = {path.name: path.read_text().strip() for path in Path("/sys/module/uvcvideo/parameters").iterdir()}
    return dict(device=actual, physical_path="1-2.4", bound_interfaces=bound,
                original_parameters=parameters, taint_before=Path("/proc/sys/kernel/tainted").read_text().strip())


def capture(command, folder, name, timeout):
    """Keep diagnostics and terminate the whole test process group on a bounded timeout."""
    full = ["runuser", "-u", "cai", "--", str(HOST / "build/environment/venv/bin/python"), "-B", *command]
    with (folder / (name + ".log")).open("w") as log:
        child = subprocess.Popen(full, cwd=HOST.parent, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        try:
            return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            return 124


def main():
    """Unload only an unused driver, test the candidate, and restore original parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trial", action="store_true", help="temporarily load the reviewed module; requires root")
    args = parser.parse_args()
    report = preflight()
    if not args.trial:
        print(json.dumps(dict(preflight_passed=True, **report), ensure_ascii=False, indent=2))
        return 0
    if os.geteuid() != 0:
        raise RuntimeError("Temporary module trial requires administrator approval")
    folder = HOST / "reports" / ("uvc-payload-trial-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    folder.mkdir()
    report.update(started_utc=datetime.now(timezone.utc).isoformat(), installed_module_replaced=False,
                  candidate_sha256=CANDIDATE_SHA, original_restored=False, tests={})
    removed = False
    params = [name + "=" + value for name, value in report["original_parameters"].items()]
    try:
        # Do not force removal. If another process opens the card after the
        # preflight, rmmod must reject the operation without affecting it.
        # Remove only uvcvideo: modprobe -r also unloads unused dependencies,
        # which would make a direct insmod fail on vb2_vmalloc_memops.
        subprocess.run(["rmmod", "uvcvideo"], check=True, timeout=15)
        removed = True
        subprocess.run(["insmod", str(CANDIDATE), *params], check=True, timeout=15)
        time.sleep(2)
        loaded = Path("/sys/module/uvcvideo/version").read_text().strip()
        if loaded != "1.1.1-pango-hagibis":
            raise RuntimeError("Unexpected candidate driver version")
        report["loaded_candidate_version"] = loaded
        # The previous 1080p trial produced the card's No Signal pattern.
        # Keep the already evidenced FPGA 720p mode and examine a settled frame.
        print("Candidate loaded; testing real Hagibis settled 720p and browser.", flush=True)
        for size in ("1280x720",):
            report["tests"][size] = capture([str(HOST / "scripts/check_hardware_inputs.py"), "--hdmi-only",
                                              "--size", size, "--hdmi-seconds", "10", "--settle-seconds", "5"], folder, size, 75)
            print(json.dumps(dict(case=size, returncode=report["tests"][size])), flush=True)
        report["tests"]["browser"] = capture([str(HOST / "scripts/check_hardware_browser.py"),
                                               "--headless", "--temporary-profile"], folder, "browser", 90)
    except Exception as error:
        report["error"] = str(error)
        print(str(error), flush=True)
    finally:
        # Restoring never modifies the installed module. Any unexpected busy
        # state is reported explicitly rather than resolved with forced unload.
        if removed:
            try:
                if Path("/sys/module/uvcvideo").exists():
                    subprocess.run(["rmmod", "uvcvideo"], check=True, timeout=15)
                # The installed original's hash was checked before the trial.
                # modprobe restores it together with any missing dependencies.
                subprocess.run(["modprobe", "uvcvideo", *params], check=True, timeout=15)
                report["restored_srcversion"] = Path("/sys/module/uvcvideo/srcversion").read_text().strip()
                report["original_restored"] = report["restored_srcversion"] == "62141F80FEED8A5C0693267"
            except Exception as error:
                report["restore_error"] = str(error)
        report["taint_after"] = Path("/proc/sys/kernel/tainted").read_text().strip()
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        (folder / "trial.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        owner = pwd.getpwnam("cai")
        for path in [folder, *folder.iterdir()]:
            os.chown(path, owner.pw_uid, owner.pw_gid)
        print(json.dumps(dict(report=str(folder / "trial.json"), restored=report["original_restored"],
                              tests=report["tests"], error=report.get("error"), restore_error=report.get("restore_error"))), flush=True)
    return 0 if report["original_restored"] and all(value == 0 for value in report["tests"].values()) and len(report["tests"]) == 2 else 2


if __name__ == "__main__":
    raise SystemExit(main())
