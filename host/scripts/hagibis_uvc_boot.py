"""Check the installed Hagibis module before desktop sessions start.

The installer copies this helper and its manifest to root-owned system paths.
Kernel-specific module precedence handles hotplug; this check also corrects an
old UVC module loaded by an early boot stage. Never force a busy module out.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess

MANIFEST = Path("/usr/local/share/pango-hagibis/manifest.json")


def sha(path):
    """Validate the exact module bytes retained during successful hardware tests."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    """Load only the matched kernel module, keeping other kernels on vendor defaults."""
    manifest = json.loads(MANIFEST.read_text())
    if os.uname().release != manifest["kernel"]:
        print("Pango Hagibis: different kernel; use vendor driver, rebuild workaround before reuse.", flush=True)
        return 0
    if sha(manifest["module"]) != manifest["module_sha256"] or sha(manifest["vendor_module"]) != manifest["vendor_sha256"]:
        raise RuntimeError("UVC module bytes changed since validation; refusing boot-time replacement")
    selected = subprocess.check_output(["modinfo", "-n", "uvcvideo"], text=True).strip()
    if Path(selected).resolve() != Path(manifest["module"]).resolve():
        raise RuntimeError("modprobe does not select the installed Hagibis workaround")
    live = Path("/sys/module/uvcvideo")
    if live.exists():
        source = (live / "srcversion").read_text().strip()
        if source == manifest["module_srcversion"]:
            print("Pango Hagibis: verified workaround already loaded.", flush=True)
            return 0
        if source != manifest["vendor_srcversion"]:
            raise RuntimeError("Unexpected loaded UVC source; do not replace it")
        if int((live / "refcnt").read_text()) != 0:
            raise RuntimeError("UVC is busy; stop previews before re-running the check")
        # Preserve dependencies and user-defined runtime parameters while
        # changing only an unused, recognized module before desktop startup.
        parameters = [p.name + "=" + p.read_text().strip() for p in (live / "parameters").iterdir()]
        subprocess.run(["rmmod", "uvcvideo"], check=True, timeout=15)
    else:
        parameters = []
    try:
        subprocess.run(["modprobe", "uvcvideo", *parameters], check=True, timeout=15)
    except Exception:
        # A rejected candidate must not leave capture devices unbound. Load
        # dependencies explicitly, then the untouched vendor module as fallback.
        depends = subprocess.check_output(["modinfo", "-F", "depends", manifest["vendor_module"]], text=True).strip()
        for name in depends.split(","):
            if name:
                subprocess.run(["modprobe", name], check=True, timeout=15)
        if not live.exists():
            subprocess.run(["insmod", manifest["vendor_module"], *parameters], check=True, timeout=15)
        raise
    if (live / "srcversion").read_text().strip() != manifest["module_srcversion"]:
        raise RuntimeError("Unexpected UVC source after boot check")
    print("Pango Hagibis: " + (live / "version").read_text().strip() + " loaded.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
