"""Audit frozen HDMI regressions and post-PnR evidence without hardware access."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

FPGA = Path(__file__).resolve().parents[1]


def read(path: Path) -> str:
    """Read tool logs, including PowerShell UTF-8 BOM and Windows line endings."""
    return path.read_text(encoding="utf-8-sig", errors="replace")


def require(condition: bool, message: str) -> None:
    """Fail evidence validation explicitly; never convert missing logs into pass."""
    if not condition:
        raise ValueError(message)


def digest(path: Path) -> str:
    """Hash complete source bytes rather than timestamps or project names."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_snapshot(run: Path, pnr: bool = False) -> None:
    """Bind reports both to retained snapshots and unchanged working inputs."""
    entries = json.loads(read(run / "source_snapshot.json"))
    for entry in entries:
        name = entry["path"].replace("\\", "/")
        original = FPGA / ("ip/" + name if pnr and name.startswith("video_pll/") else name)
        copied = run / "source" / name
        require(digest(copied) == entry["sha256"], f"Snapshot changed: {copied}")
        require(digest(original) == entry["sha256"], f"Working source differs: {original}")


def resources(run: Path) -> dict:
    """Extract same-fixture synthesis usage, including memories/serial clocks."""
    text = read(run / "synthesize/hdmi_display_pnr_probe.snr")
    result = {}
    for key, expression in {
        "lut": r"Total LUTs:\s+(\d+)",
        "registers": r"Total Registers:\s+(\d+)",
        "drm36k": r"Total DRM\s*=\s*([\d.]+)",
        "apm": r"Total APMs\s*=\s*([\d.]+)",
        "oserdes": r"GTP_OSERDES_E2\s+(\d+) uses",
        "gpll": r"GTP_GPLL\s+(\d+) use",
        "ioclkbuf": r"GTP_IOCLKBUF\s+(\d+) use",
        "ioclkdiv": r"GTP_IOCLKDIV_E2\s+(\d+) use",
    }.items():
        match = re.search(expression, text)
        require(match is not None, f"Missing resource: {key}")
        result[key] = float(match[1])
    return result


def timing(run: Path) -> dict:
    """Use final report_timing, both corners and min/max; no logic-level filter."""
    text = read(run / "report_timing/hdmi_display_pnr_probe.rtr")
    require("All Constraints Met" in text, "PnR has failing constrained paths")
    require("Timing analysis mode : multi corner" in text, "Missing multi-corner timing")
    wave = re.search(r"pixel_clk\s+([\d.]+)\s+\{([\d.]+)\s+([\d.]+)\}", text)
    require(wave is not None, "Missing pixel clock waveform")
    period, rising, falling = map(float, wave.groups())
    require(abs(period - 13.468) < 0.002, "Wrong pixel period")
    require(abs((falling - rising) / period - 0.4) < 0.001, "Native /5 needs 40% duty")
    summaries = {}
    for mode in ("Setup", "Hold", "Recovery", "Removal"):
        for corner in ("Slow", "Fast"):
            part = re.search(rf"{mode} Summary\({corner} Corner\):(.*?)(?=\n=+)", text, re.S)
            require(part is not None, f"Missing {mode}/{corner}")
            rows = []
            for match in re.finditer(r"^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$", part[1], re.M):
                launch, capture, slack, total, failing, endpoints = match.groups()
                require(float(slack) >= 0 and float(total) == 0 and int(failing) == 0,
                        f"Violation: {mode}/{corner}/{launch}->{capture}")
                rows.append({"launch": launch, "capture": capture, "slack_ns": float(slack),
                             "total_negative_ns": float(total), "endpoints": int(endpoints)})
            require(bool(rows), f"No paths: {mode}/{corner}")
            summaries[f"{mode.lower()}_{corner.lower()}"] = rows
    # Data/serializer exceptions must not be broadened to fabricate timing.
    fdc = read(run / "source/constraints/hdmi_display_probe.fdc")
    exceptions = [line.strip() for line in fdc.splitlines() if line.startswith("set_false_path")]
    require(len(exceptions) == 2 and "reset_n" in exceptions[0] and "video_div_reset_n" in exceptions[1],
            "Unexpected false-path scope")
    return {"period_ns": period, "high_ns": falling - rising, "summaries": summaries,
            "exceptions": exceptions, "external_output_signoff": False}


def simulated_metrics(run: Path, case: str) -> dict:
    """Parse explicit end-of-test counters instead of inferring from elapsed time."""
    text = read(run / f"{case}.log")
    require("HDMI_DISPLAY_PASS" in text, f"Missing completion marker: {case}")
    line = re.search(r"HDMI_DISPLAY_PASS (.*)", text)[1]
    return {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}


def main() -> None:
    """Produce a reproducible local evidence summary and explicit integration limits."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--pnr", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    require(out.is_relative_to((FPGA / "build").resolve()), "Output must be inside fpga/build")
    verify_snapshot(args.sim)
    verify_snapshot(args.pnr, pnr=True)
    sim = json.loads(read(args.sim / "result.json"))
    required_cases = {"faults", "mixed_dma", "encoding", "mini_video", "1080p30"}
    require(required_cases <= sim["cases"].keys() and all(sim["cases"][c] for c in required_cases),
            "All five regressions must finish successfully")
    full, mixed = (simulated_metrics(args.sim, c) for c in ("1080p30", "mixed_dma"))
    require(full["pixels"] == full["good_pixels"] == 6220800 and full["failed"] == full["underflow"] == 0,
            "Full 1080p payload/underflow mismatch")
    require(mixed["native"] == 1 and mixed["failed"] == mixed["underflow"] == 0, "Mixed DMA failed")
    require(mixed["max_line_fill_cycles"] <= 2474, "Mixed DMA line deadline miss")
    result = {"local_validation_passed": True, "sim": str(args.sim), "pnr": str(args.pnr),
              "full_1080p": full, "mixed_dma": mixed, "resources": resources(args.pnr),
              "timing": timing(args.pnr), "hardware_tested": False, "programmed": False,
              "source_frame_id_at_capture_card": None, "pairing_status": "unverified",
              "native_serializer_rerun": "blocked_by_ModelSim_license",
              "integration": "shared top/DDR-domain CDC/frame-pool transaction adapter pending"}
    # Exact line-bank reuse geometry, with two setup cycles and one strict edge
    # margin. This budget is conditional on admitted DDR/CDC service progressing.
    result["deadline"] = {"line_bank_reuse_cycles": 2477, "request_setup_cycles": 2,
                          "strict_prepare_margin_cycles": 1, "line_service_budget_cycles": 2474,
                          "mixed_measured_margin_cycles": 2474 - mixed["max_line_fill_cycles"]}
    if args.baseline:
        before = resources(args.baseline)
        after = result["resources"]
        result["comparison"] = {"baseline": str(args.baseline), "before": before,
                                "lut_reduction_percent": 100 * (before["lut"] - after["lut"]) / before["lut"],
                                "register_reduction_percent": 100 * (before["registers"] - after["registers"]) / before["registers"],
                                "baseline_timing": timing(args.baseline)}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"HDMI_EVIDENCE_AUDIT_PASS {out}")


if __name__ == "__main__":
    main()
