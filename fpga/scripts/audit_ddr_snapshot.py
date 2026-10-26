"""Audit actual diagnostic dependencies after a concurrent edit in the workspace.

The broad snapshot includes unrelated FPGA sources. Report every changed file,
but certify only the Tcl design/IP/constraint closure, never the whole workspace.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path


def sha(path: Path) -> str:
    """Hash raw inputs, preserving native IP/source byte identity."""
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main() -> None:
    """Resolve Tcl-listed dependencies and compare source/snapshot evidence."""
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parent.parent
    run = args.run.resolve()
    if not run.is_relative_to(fpga / "build" / "ddr_dma"):
        raise ValueError("audit run must remain under fpga/build/ddr_dma")
    snapshot = run / "workspace" / "fpga"
    tcl = Path("project/mini_camera_diag/mini_camera_diag.tcl")
    text = (snapshot / tcl).read_text(encoding="utf-8-sig")
    direct = set()
    ip_dirs = []
    for parts in re.findall(r"add_(?:design|constraint) \[file join \$fpga_root (.+?)\]", text):
        path = Path(*parts.split())
        direct.add(path.as_posix())
        if path.suffix == ".idf":
            ip_dirs.append(path.parent.as_posix() + "/")
    # Generated diagnostic constraints depend on the original board/native FDCs.
    direct.update({"constraints/board_pins.fdc", "constraints/ddr_native.fdc"})
    changes, dependency_changes = [], []
    for entry in json.loads((run / "source_snapshot.json").read_text(encoding="utf-8-sig")):
        relative = entry["path"].replace("\\", "/")
        source = fpga / relative
        if not source.exists() or sha(source) != entry["sha256"]:
            changes.append(relative)
            if relative in direct or any(relative.startswith(prefix) for prefix in ip_dirs):
                dependency_changes.append(relative)
    tcl_match = sha(fpga / tcl) == sha(snapshot / tcl)
    result = {
        "all_snapshot_inputs_unchanged": not changes,
        "changed_inputs": changes,
        "diagnostic_dependency_changes": dependency_changes,
        "diagnostic_tcl_unchanged": tcl_match,
        "diagnostic_inputs_match_snapshot": not dependency_changes and tcl_match,
        "hardware_tested": False,
        "release_ready": False,
    }
    (run / "dependency_audit.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    if not result["diagnostic_inputs_match_snapshot"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
