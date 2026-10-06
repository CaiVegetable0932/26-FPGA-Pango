"""Prepare a device-specific fix using the fingerprint-matched Seeed baseline.

Retain Seeed's compressed-payload override for all other devices. This builder
does not load a module or modify the installed JetPack/kernel configuration.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_hagibis_uvc_queue import info, versions

HOST = Path(__file__).resolve().parents[1]
BUILD = HOST / "build/uvc-diagnostic"


def main():
    """Require matching vendor sources and ABI before producing a loadable candidate."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true", help="recheck the preserved candidate without rewriting sources")
    args = parser.parse_args()
    baseline = BUILD / "seeed-baseline"
    original = BUILD / "original-uvcvideo.ko"
    installed = Path("/lib/modules/5.15.148-tegra/kernel/drivers/media/usb/uvc/uvcvideo.ko")
    if original.read_bytes() != installed.read_bytes():
        raise RuntimeError("Installed module differs from preserved original")
    if info(baseline / "uvcvideo.ko", "srcversion") != info(original, "srcversion"):
        raise RuntimeError("Seeed baseline source identity does not match installed module")
    candidate = BUILD / "hagibis-payload"
    if candidate.exists() and not args.verify_only:
        raise RuntimeError("Candidate directory already exists; refusing to overwrite evidence")
    if args.verify_only:
        return verify(baseline, original, candidate)
    candidate.mkdir()
    for source in baseline.iterdir():
        if source.name == "Makefile" or source.suffix == ".h" or (source.suffix == ".c" and not source.name.endswith(".mod.c")):
            shutil.copy2(source, candidate / source.name)
    video = candidate / "uvc_video.c"
    before = video.read_text()
    old = "\tif (format->flags & UVC_FMT_FLAG_COMPRESSED) {\n\t\t\tctrl->dwMaxPayloadTransferSize = 0x300;\n\t}"
    new = '''\t/* Pango Hagibis diagnostic: retain the device-negotiated bulk payload.
\t * Seeed's 768-byte compressed override fragments this Actions device's
\t * MJPEG payloads; preserve the vendor behavior for every other device.
\t */
\tif ((format->flags & UVC_FMT_FLAG_COMPRESSED) &&
\t    !(le16_to_cpu(stream->dev->udev->descriptor.idVendor) == 0x1de1 &&
\t      le16_to_cpu(stream->dev->udev->descriptor.idProduct) == 0xf105 &&
\t      stream->dev->udev->product &&
\t      !strcmp(stream->dev->udev->product, "Hagibis"))) {
\t\tctrl->dwMaxPayloadTransferSize = 0x300;
\t}'''
    if before.count(old) != 1:
        raise RuntimeError("Expected unique Seeed compressed-payload override")
    after = before.replace(old, new)
    video.write_text(after)
    patch = "".join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                      fromfile="seeed-baseline/uvc_video.c", tofile="hagibis-payload/uvc_video.c"))
    header = candidate / "uvcvideo.h"
    before_header = header.read_text()
    after_header = before_header.replace('#define DRIVER_VERSION\t\t"1.1.1"',
                                        '#define DRIVER_VERSION\t\t"1.1.1-pango-hagibis"')
    if before_header == after_header:
        raise RuntimeError("Unexpected baseline driver version")
    header.write_text(after_header)
    patch += "".join(difflib.unified_diff(before_header.splitlines(True), after_header.splitlines(True),
                                       fromfile="seeed-baseline/uvcvideo.h", tofile="hagibis-payload/uvcvideo.h"))
    (BUILD / "hagibis-payload.patch").write_text(patch)
    with (BUILD / "build-hagibis-payload.log").open("w") as output:
        subprocess.run(["make", "-C", str(BUILD / "headers"), "ARCH=arm64", "M=" + str(candidate),
                        "modules", "-j2"], stdout=output, stderr=subprocess.STDOUT, check=True)
    verify(baseline, original, candidate)


def verify(baseline, original, candidate):
    """Validate new imports against matched kernel headers, existing imports against both."""
    original_versions = versions(original)
    # The product-name check introduces strcmp. A newly imported symbol must
    # match the running release's copied Module.symvers, not be rejected merely
    # because the untouched UVC module did not previously import that symbol.
    header_versions = {fields[1]: fields[0] for line in (BUILD / "headers/Module.symvers").read_text().splitlines()
                       if len(fields := line.split()) >= 2}
    modules = {}
    for name, module in (("original", original), ("seeed-baseline", baseline / "uvcvideo.ko"),
                         ("hagibis-payload", candidate / "uvcvideo.ko")):
        imported = versions(module)
        modules[name] = dict(path=str(module), sha256=hashlib.sha256(module.read_bytes()).hexdigest(),
                             version=info(module, "version"), srcversion=info(module, "srcversion"),
                             vermagic=info(module, "vermagic"), imported_symbol_count=len(imported),
                             added_imports={key: value for key, value in imported.items() if key not in original_versions},
                             abi_mismatches={key: value for key, value in imported.items()
                                             if header_versions.get(key) != value or
                                             (key in original_versions and original_versions[key] != value)})
    checks = dict(baseline_source_identity_matches=modules["seeed-baseline"]["srcversion"] == modules["original"]["srcversion"],
                  candidate_vermagic_matches=modules["hagibis-payload"]["vermagic"] == modules["original"]["vermagic"],
                  candidate_abi_matches=not modules["hagibis-payload"]["abi_mismatches"],
                  baseline_abi_matches=not modules["seeed-baseline"]["abi_mismatches"])
    report = dict(modules=modules, checks=checks, UVC_URBS=5, UVC_MAX_PACKETS=32,
                  source_url="https://github.com/Seeed-Studio/Linux_for_Tegra/blob/798d0238554f3385e185ef3610025dbbba0c54f0/source/kernel/kernel-jammy-src/drivers/media/usb/uvc/uvc_video.c",
                  driver_loaded=False, installed_module_replaced=False)
    (BUILD / "payload-build-check.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not all(checks.values()):
        raise RuntimeError("Compatibility validation failed; do not load candidate")


if __name__ == "__main__":
    main()
