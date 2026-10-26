"""Persist the exact verified Hagibis driver and desktop startup configuration.

Install a kernel-specific override alongside the untouched vendor module, plus
a boot check and a serial-specific autosuspend rule. Only owned, hash-matched
files can be removed. No initrd, bootloader, clocks or JetPack package changes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess
import tempfile

HOST = Path(__file__).resolve().parents[1]
KERNEL = "5.15.148-tegra"
CANDIDATE_SHA = "2ba0ffd9ed762064486430eb02a61172ffe244b02542f4a83531f4b24d8f0120"
VENDOR_SHA = "555d9945e8ac1f4a5f3b3eb5d0d8f7765b18dbaf8457b4fbd15b39947baa53eb"
VENDOR = Path("/lib/modules") / KERNEL / "kernel/drivers/media/usb/uvc/uvcvideo.ko"
MODULE = Path("/lib/modules") / KERNEL / "updates/pango/uvcvideo.ko"
STATE = Path("/usr/local/share/pango-hagibis")
MANIFEST = STATE / "manifest.json"
UNIT = "pango-hagibis-uvc.service"


def digest(data):
    """Tie installation and rollback to reviewed bytes instead of just filenames."""
    return hashlib.sha256(data).hexdigest()


def run(command):
    """Bound each system maintenance command; never force removal or module loading."""
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)


def plan():
    """Construct a concrete reviewable set of system and desktop-user files."""
    sources = {
        MODULE: HOST / "build/uvc-diagnostic/hagibis-payload/uvcvideo.ko",
        Path("/etc/depmod.d/90-pango-hagibis.conf"): HOST / "config/pango-hagibis-depmod.conf",
        Path("/etc/systemd/system") / UNIT: HOST / "config/pango-hagibis-uvc.service",
        Path("/usr/local/libexec/pango/hagibis_uvc_boot.py"): HOST / "scripts/hagibis_uvc_boot.py",
        Path("/usr/local/libexec/pango/open_workbench_at_login.sh"): HOST / "scripts/open_workbench_at_login.sh",
        Path("/etc/udev/rules.d/99-pango-hagibis-no-autosuspend.rules"): HOST / "config/99-pango-hagibis-persistent.rules",
        Path("/home/cai/.config/systemd/user/pango-host.service"): HOST / "config/pango-host-login.service",
        Path("/home/cai/.config/autostart/pango-workbench.desktop"): HOST / "config/pango-workbench.desktop",
        STATE / "vendor-uvcvideo.ko": HOST / "build/uvc-diagnostic/original-uvcvideo.ko",
    }
    return {str(target): source.read_bytes() for target, source in sources.items()}


def atomic_write(path, data, desktop=False):
    """Copy immutable system snapshots; let the normal user own their session files."""
    path = Path(path)
    owner = pwd.getpwnam("cai")
    missing = []
    parent = path.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o755)
        if desktop:
            os.chown(directory, owner.pw_uid, owner.pw_gid)
    fd, temporary = tempfile.mkstemp(prefix=".pango-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        if desktop:
            os.chown(temporary, owner.pw_uid, owner.pw_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(files):
    """Commit validated files, verify depmod resolution, then enable boot/login startup."""
    if os.uname().release != KERNEL or digest(VENDOR.read_bytes()) != VENDOR_SHA:
        raise RuntimeError("Current kernel or vendor module no longer matches the hardware-tested baseline")
    if digest(files[str(MODULE)]) != CANDIDATE_SHA or digest(files[str(STATE / "vendor-uvcvideo.ko")]) != VENDOR_SHA:
        raise RuntimeError("Reviewed candidate or backup changed")
    build = json.loads((HOST / "build/uvc-diagnostic/payload-build-check.json").read_text())
    if not all(build["checks"].values()):
        raise RuntimeError("Build ABI validation failed")
    # An already committed installation is rechecked without rewriting its
    # transaction state or disabling its startup if the recheck fails.
    if MANIFEST.exists():
        previous = json.loads(MANIFEST.read_text())
        if not previous.get("install_verified") or previous.get("files") != {name: digest(data) for name, data in files.items()}:
            raise RuntimeError("Existing installation differs; inspect it before changing persistence")
        for name, expected in previous["files"].items():
            if Path(name).is_symlink() or digest(Path(name).read_bytes()) != expected:
                raise RuntimeError("Previously installed file changed: " + name)
        run(["systemctl", "start", UNIT])
        print("The identical committed Hagibis strategy is already installed and was rechecked.")
        return
    # Refuse to adopt unrelated files or symlinks. A repeat installation is safe
    # only if every destination has exactly the intended current bytes.
    for name, data in files.items():
        target = Path(name)
        if target.is_symlink() or (target.exists() and target.read_bytes() != data):
            raise RuntimeError("Destination differs; refusing overwrite: " + name)
    user_link = Path("/home/cai/.config/systemd/user/default.target.wants/pango-host.service")
    if user_link.exists() or user_link.is_symlink():
        if not user_link.is_symlink() or os.readlink(user_link) != "../pango-host.service":
            raise RuntimeError("User startup link differs")
    volatile = Path("/run/udev/rules.d/99-pango-hagibis-no-autosuspend.rules")
    if volatile.exists() and volatile.read_bytes() != (HOST / "config/99-pango-hagibis-no-autosuspend.rules").read_bytes():
        raise RuntimeError("Existing volatile diagnostic rule differs")
    manifest = dict(kernel=KERNEL, module=str(MODULE), module_sha256=CANDIDATE_SHA,
                    module_srcversion="07CEFA74AE992273053776F", vendor_module=str(VENDOR),
                    vendor_sha256=VENDOR_SHA, vendor_srcversion="62141F80FEED8A5C0693267",
                    files={name: digest(data) for name, data in files.items()},
                    user_startup_link=str(user_link), installed_utc=datetime.now(timezone.utc).isoformat(),
                    initrd_changed=False, vendor_module_replaced=False)
    created = []
    link_created = False
    # A failed first installation must restore the prior temporary rule too.
    volatile_data = volatile.read_bytes() if volatile.exists() else None
    try:
        for name, data in files.items():
            if not Path(name).exists():
                created.append(Path(name))
            atomic_write(name, data, desktop=name.startswith("/home/cai/"))
        atomic_write(MANIFEST, (json.dumps(manifest, indent=2) + "\n").encode())
        run(["depmod", "-a", KERNEL])
        selected = run(["modinfo", "-n", "uvcvideo"]).stdout.strip()
        if Path(selected).resolve() != MODULE.resolve():
            raise RuntimeError("depmod did not select the Hagibis override")
        run(["systemd-analyze", "verify", "/etc/systemd/system/" + UNIT])
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "enable", UNIT])
        # Enable the user's standard target without starting a second receiver
        # while the current manually launched server still owns its UDP port.
        if not user_link.is_symlink():
            owner = pwd.getpwnam("cai")
            user_link.parent.mkdir(exist_ok=True)
            os.chown(user_link.parent, owner.pw_uid, owner.pw_gid)
            user_link.symlink_to("../pango-host.service")
            os.lchown(user_link, owner.pw_uid, owner.pw_gid)
            link_created = True
        if volatile.exists():
            volatile.unlink()
        run(["udevadm", "control", "--reload-rules"])
        # Starting this check is harmless if the same workaround is already
        # loaded; it neither reloads that module nor interrupts existing video.
        result = run(["systemctl", "start", UNIT])
        manifest["install_verified"] = True
        atomic_write(MANIFEST, (json.dumps(manifest, indent=2) + "\n").encode())
        print(json.dumps(dict(installed=True, module=selected, boot_service=UNIT,
                              desktop_login_startup=True, vendor_module_replaced=False,
                              stdout=result.stdout), ensure_ascii=False))
    except Exception:
        # Never leave a partially installed override selected after failure.
        subprocess.run(["systemctl", "disable", UNIT], capture_output=True, timeout=30)
        for target in reversed(created):
            if target.exists():
                target.unlink()
        if link_created and user_link.is_symlink() and os.readlink(user_link) == "../pango-host.service":
            user_link.unlink()
        if MANIFEST.exists():
            MANIFEST.unlink()
        subprocess.run(["depmod", "-a", KERNEL], capture_output=True, timeout=60)
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True, timeout=30)
        if volatile_data is not None and not volatile.exists():
            atomic_write(volatile, volatile_data)
        subprocess.run(["udevadm", "control", "--reload-rules"], capture_output=True, timeout=30)
        raise


def uninstall():
    """Remove only owned hash-matched persistence; leave busy capture until reboot."""
    manifest = json.loads(MANIFEST.read_text())
    for name, expected in manifest["files"].items():
        target = Path(name)
        if target.is_symlink() or (target.exists() and digest(target.read_bytes()) != expected):
            raise RuntimeError("Installed file changed; refusing removal: " + name)
    link = Path(manifest["user_startup_link"])
    if link.is_symlink() and os.readlink(link) != "../pango-host.service":
        raise RuntimeError("User startup link changed")
    run(["systemctl", "disable", "--now", UNIT])
    if link.is_symlink():
        link.unlink()
    for name in reversed(list(manifest["files"])):
        target = Path(name)
        if target.exists():
            target.unlink()
    MANIFEST.unlink()
    run(["depmod", "-a", KERNEL])
    run(["systemctl", "daemon-reload"])
    run(["udevadm", "control", "--reload-rules"])
    print("Owned persistence removed. Reboot restores the vendor module and default device PM; current capture was not interrupted.")


def verify_load():
    """Exercise the installed boot loader with an unused driver, then retain the fix."""
    manifest = json.loads(MANIFEST.read_text())
    if os.uname().release != manifest["kernel"]:
        raise RuntimeError("Kernel changed since installation")
    for name, expected in manifest["files"].items():
        if digest(Path(name).read_bytes()) != expected:
            raise RuntimeError("Installed file changed: " + name)
    live = Path("/sys/module/uvcvideo")
    if not live.exists() or (live / "srcversion").read_text().strip() != manifest["module_srcversion"]:
        raise RuntimeError("Unexpected loaded driver before reload test")
    if int((live / "refcnt").read_text()) != 0:
        raise RuntimeError("Close HDMI previews before the installed-driver reload test")
    bound = [p.name for p in Path("/sys/bus/usb/drivers/uvcvideo").glob("*:*") if p.is_symlink()]
    if any(not name.startswith("1-2.4:") for name in bound):
        raise RuntimeError("Other UVC devices present; refusing shared driver reload")
    # Use the installed service, not a project insmod path, to reproduce normal
    # boot-time dependency/module selection. Never force module removal.
    run(["rmmod", "uvcvideo"])
    try:
        run(["systemctl", "restart", UNIT])
    except Exception:
        if not live.exists():
            run(["modprobe", "uvcvideo"])
        raise
    if (live / "srcversion").read_text().strip() != manifest["module_srcversion"]:
        raise RuntimeError("Installed boot loader did not restore the expected workaround")
    print(json.dumps(dict(installed_boot_load_verified=True, loaded_version=(live / "version").read_text().strip(),
                          loaded_srcversion=(live / "srcversion").read_text().strip()), ensure_ascii=False))


def main():
    """Preview planned files as normal user; require administrator rights only to install."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "install", "uninstall", "verify-load"))
    args = parser.parse_args()
    if args.action == "plan":
        print(json.dumps({name: dict(bytes=len(data), sha256=digest(data)) for name, data in plan().items()}, indent=2))
        return
    if os.geteuid() != 0:
        raise RuntimeError("Administrator approval required to persist system configuration")
    if args.action == "install":
        install(plan())
    elif args.action == "uninstall":
        uninstall()
    else:
        verify_load()


if __name__ == "__main__":
    main()
