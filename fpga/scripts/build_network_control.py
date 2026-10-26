"""Snapshot section07 sources and run isolated installed-version PDS flow.

No board project, official reference, generated IP, bitstream or hardware write.
Success distinguishes tool completion from positive setup/hold sign-off. Only
internal timing is constrained; external IO remains explicitly unverified.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

FPGA = Path(__file__).resolve().parents[1]


def main() -> None:
    """Build an immutable source snapshot and preserve failed experiments too."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=("network", "control"), required=True)
    parser.add_argument("--pds-home", type=Path, default=Path("E:/PDS_Pangu/PDS_2022.2-SP6.4"))
    args = parser.parse_args()
    run = FPGA / "build/network_control_20261012" / datetime.now().strftime(f"pds_{args.group}_%Y%m%d_%H%M%S_%f")
    snapshot = run / "source_snapshot"
    snapshot.mkdir(parents=True)
    paths = sorted((FPGA / "rtl/network").glob("*.sv")) + sorted((FPGA / "rtl/control").glob("*.sv"))
    paths += [FPGA / "sim/network_timing_top.sv", FPGA / "sim/control_timing_top.sv",
              FPGA / "rtl/memory/dma_byte_unpack.v", FPGA / "constraints/network_control_internal.fdc"]
    hashes = {}
    for path in paths:
        relative = path.relative_to(FPGA)
        target = snapshot / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        hashes[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()
    script = FPGA / "scripts/build_network_control.tcl"
    hashes[str(script.relative_to(FPGA))] = hashlib.sha256(script.read_bytes()).hexdigest()
    (run / "source_hashes.json").write_text(json.dumps(hashes, indent=2)+"\n")
    child_env = os.environ.copy()
    child_env["PANGO_07_CONTROL"] = "1" if args.group == "control" else "0"
    child_env["PANGO_07_BUILD"] = str(run)
    print(f"PDS_07_START {run}", flush=True)
    with (run / "console.log").open("w", encoding="utf-8") as log:
        result = subprocess.run([str(args.pds_home / "bin/pds_shell.exe"), "-file", str(script), "-work_dir", str(run)],
                                cwd=run, env=child_env, stdout=log, stderr=subprocess.STDOUT,
                                timeout=1800, creationflags=0x08000000)
    top = args.group + "_timing_top"
    report = run / f"report_timing/{top}.rtr"
    summary = dict(native_exit=result.returncode, tool_completed=report.exists() and result.returncode == 0,
                   setup_hold_passed=False, external_io_verified=False, hardware_tested=False, programmed=False,
                   group=args.group, run=str(run))
    if report.exists():
        text = report.read_text(errors="replace")
        timing = re.search(r"network_clk\s+125\.0000 MHz\s+([\d.]+) MHz\s+8\.0000\s+([\d.]+)\s+(-?[\d.]+)", text)
        if timing:
            summary.update(estimated_MHz=float(timing[1]), estimated_period_ns=float(timing[2]), setup_wns_ns=float(timing[3]))
        # Report explicitly covers min/max; require every summary to pass, not
        # merely process exit or a filtered 20-path report listing.
        summary["setup_hold_passed"] = "Some Constraints Violated" not in text and summary["tool_completed"]
    (run / "result.json").write_text(json.dumps(summary, indent=2)+"\n")
    print(json.dumps(summary), flush=True)
    if not summary["tool_completed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
