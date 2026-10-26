"""Build a forum-derived UVC queue candidate entirely inside the project.

The official R36.4.3 UVC sources must be extracted into baseline first. Use a
copy of installed kernel headers/config/symbol versions, preserve the original
module, and check baseline source identity and candidate ABI before any loading.
This script does not install modules or modify the running kernel.
"""
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

HOST = Path(__file__).resolve().parents[1]
BUILD = HOST / "build/uvc-diagnostic"


def run(command):
    """Keep complete build output in a file and fail on any compiler error."""
    name = "build-" + Path(command[4].split("=", 1)[1]).name
    with (BUILD / (name + ".log")).open("w") as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)


def info(module, field):
    """Inspect metadata without loading code into the kernel."""
    return subprocess.check_output(["modinfo", "-F", field, str(module)], text=True).strip()


def versions(module):
    """Compare the imported symbol CRCs against the running module's ABI."""
    return dict(line.split()[::-1] for line in subprocess.check_output(
        ["modprobe", "--dump-modversions", str(module)], text=True).splitlines())


def main():
    """Compile baseline and candidate, retain exact patches and compatibility evidence."""
    baseline = BUILD / "baseline"
    candidate = BUILD / "queue100"
    installed = Path("/lib/modules/5.15.148-tegra/kernel/drivers/media/usb/uvc/uvcvideo.ko")
    original = BUILD / "original-uvcvideo.ko"
    if original.exists() and original.read_bytes() != installed.read_bytes():
        raise RuntimeError("Existing original backup differs; refusing to overwrite it")
    shutil.copy2(installed, original)
    if candidate.exists():
        raise RuntimeError("Candidate directory already exists; inspect it before rebuilding")
    shutil.copytree(baseline, candidate)
    header = candidate / "uvcvideo.h"
    before = header.read_text()
    after = before
    for macro, old, new in (("UVC_URBS", "5", "100"), ("UVC_MAX_PACKETS", "32", "64")):
        pattern = r"(#define\s+" + macro + r"\s+)" + old + r"\b"
        after, count = re.subn(pattern, lambda match: match.group(1) + new, after)
        if count != 1:
            raise RuntimeError("Unexpected upstream default for " + macro)
    after = after.replace('#define DRIVER_VERSION\t\t"1.1.1"',
                          '#define DRIVER_VERSION\t\t"1.1.1-pango-q100"')
    if '"1.1.1-pango-q100"' not in after:
        raise RuntimeError("Unexpected driver version definition")
    # Mark the limited experiment in the candidate source, retaining pristine
    # baseline and a reviewable diff. Queue counts follow the JetPack 6.2.1 case.
    after = after.replace("#define UVC_URBS", "/* Pango diagnostic: larger UVC queues; no OS power/clock changes. */\n#define UVC_URBS", 1)
    header.write_text(after)
    (BUILD / "queue100.patch").write_text("".join(difflib.unified_diff(
        before.splitlines(True), after.splitlines(True), fromfile="baseline/uvcvideo.h",
        tofile="queue100/uvcvideo.h")))
    for path in (baseline, candidate):
        run(["make", "-C", str(BUILD / "headers"), "ARCH=arm64", "M=" + str(path), "modules", "-j2"])
    original_versions = versions(original)
    modules = {}
    for name, module in (("original", original), ("baseline", baseline / "uvcvideo.ko"),
                         ("queue100", candidate / "uvcvideo.ko")):
        imported = versions(module)
        modules[name] = {"path": str(module), "sha256": hashlib.sha256(module.read_bytes()).hexdigest(),
                         "version": info(module, "version"), "srcversion": info(module, "srcversion"),
                         "vermagic": info(module, "vermagic"), "imported_symbol_count": len(imported),
                         "abi_mismatches": {key: value for key, value in imported.items()
                                            if original_versions.get(key) != value}}
    report = {"modules": modules,
              "source_url": "https://developer.download.nvidia.com/embedded/L4T/r36_Release_v4.3/sources/public_sources.tbz2",
              "forum_case": "https://forums.developer.nvidia.com/t/usb-camera-frames-freezes-randomly-in-jetpack-6-2-1/344107/13",
              "baseline_source_identity_matches": modules["baseline"]["srcversion"] == modules["original"]["srcversion"],
              "candidate_vermagic_matches": modules["queue100"]["vermagic"] == modules["original"]["vermagic"],
              "candidate_abi_matches": not modules["queue100"]["abi_mismatches"],
              "queue_parameters": {"UVC_URBS": 100, "UVC_MAX_PACKETS": 64},
              "driver_loaded": False, "installed_module_replaced": False}
    (BUILD / "build-check.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not all(report[key] for key in ("baseline_source_identity_matches", "candidate_vermagic_matches", "candidate_abi_matches")):
        raise RuntimeError("Compatibility check failed; do not load candidate")


if __name__ == "__main__":
    main()
