"""Record Hagibis USB/UVC compatibility evidence without changing OS settings.

This probe neither opens a capture stream nor writes to sysfs. Runtime PM
counters can establish that suspend occurred, but cannot prove why video failed.
"""
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import subprocess

HOST = Path(__file__).resolve().parents[1]


def read(path):
    """Keep absent or inaccessible attributes distinct from a zero value."""
    try:
        return Path(path).read_text().strip()
    except OSError as error:
        return {"error": str(error)}


def command(args):
    """Retain read-only command results with a bounded execution time."""
    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
    return {"returncode": result.returncode, "stdout": result.stdout,
            "stderr": result.stderr}


def main():
    """Match the physical card, compare loaded/file modules and retain PM state."""
    devices = []
    for path in sorted(Path("/sys/bus/usb/devices").glob("*")):
        if read(path / "idVendor") != "1de1" or read(path / "idProduct") != "f105":
            continue
        attributes = ("idVendor", "idProduct", "bcdDevice", "product", "manufacturer",
                      "serial", "speed", "busnum", "devnum", "power/control",
                      "power/runtime_status", "power/runtime_active_time",
                      "power/runtime_suspended_time", "power/autosuspend_delay_ms")
        devices.append({"physical_path": path.name,
                        "attributes": {name: read(path / name) for name in attributes}})
    aliases = command(["modinfo", "-F", "alias", "uvcvideo"])
    # The upstream Actions UVC05 patch adds a device-specific table entry and
    # therefore an exact USB alias. Absence is evidence that this entry is absent;
    # it does not exclude a downstream fix implemented by some other mechanism.
    exact_aliases = [line for line in aliases["stdout"].splitlines()
                     if "V1DE1PF105" in line.upper()]
    report = {
        "recorded_utc": datetime.now(timezone.utc).isoformat(),
        "settings_changed": False,
        "kernel": platform.uname()._asdict(),
        "l4t_release": read("/etc/nv_tegra_release"),
        "usb_devices": devices,
        "unique_hagibis": len(devices) == 1 and devices[0]["attributes"]["product"] == "Hagibis",
        "loaded_uvc_srcversion": read("/sys/module/uvcvideo/srcversion"),
        "file_uvc_srcversion": command(["modinfo", "-F", "srcversion", "uvcvideo"]),
        "file_uvc_version": command(["modinfo", "-F", "version", "uvcvideo"]),
        "file_uvc_filename": command(["modinfo", "-F", "filename", "uvcvideo"]),
        "exact_device_uvc_aliases": exact_aliases,
        "alias_command_returncode": aliases["returncode"],
        "uvc_quirks_parameter": read("/sys/module/uvcvideo/parameters/quirks"),
        "usbcore_autosuspend_seconds": read("/sys/module/usbcore/parameters/autosuspend"),
        "usb_topology": command(["lsusb", "-t"]),
        "video_nodes": [{"path": str(path), "target": str(path.resolve())}
                        for path in sorted(Path("/dev/v4l/by-path").glob("*-video-index0"))],
        "nvidia_packages": command(["dpkg-query", "-W", "-f=${Package}\t${Version}\n",
                                    "nvidia-jetpack", "nvidia-l4t-core", "nvidia-l4t-kernel",
                                    "nvidia-l4t-gstreamer"]),
        "upstream_patch": {
            "commit": "8c54e58f94ed3ff28643aefd2c0c2c98313ee770",
            "title": "media: uvcvideo: Add quirk for Actions UVC05",
            "mail": "https://lkml.iu.edu/2412.1/03128.html",
            "fix": "UVC_QUIRK_DISABLE_AUTOSUSPEND for USB 1de1:f105",
            "causality_confirmed": False,
        },
    }
    folder = HOST / "reports/hardware_inputs_20261003"
    folder.mkdir(parents=True, exist_ok=True)
    output = folder / "compatibility-probe.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
