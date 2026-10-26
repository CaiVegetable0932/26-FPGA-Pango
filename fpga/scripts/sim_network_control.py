"""Reproducible section07 offline regression; no hardware/external network/download.

Compile failures and timeouts are fatal, each case retains exact stdout/exit.
Run artifacts include source hashes and tool version; existing work is preserved.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from network_control_vectors import FPGA, ROOT, vectors, verify_wire

CASES = ("uart_v2_parser", "mcu_readonly_client", "control_services", "uart_8n1",
         "ethernet_control", "network_cancel", "praw_packets", "parameter_guard", "counter_snapshot_cdc", "raw_dma_reader", "raw_network")


def command(args: list[str], run: Path, log: str, timeout: int) -> str:
    """Execute argument arrays with bounded runtime, never construct shell text."""
    child_env = os.environ.copy()
    child_env["PYTHONPATH"] = os.pathsep.join(filter(None, (
        str(ROOT / "host/src"), str(ROOT / "host/build/python_packages"), child_env.get("PYTHONPATH"))))
    result = subprocess.run(args, cwd=run, capture_output=True, text=True, env=child_env,
                            timeout=timeout, creationflags=0x08000000 if sys.platform == "win32" else 0)
    output = result.stdout + result.stderr
    (run / log).write_text(output, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"exit {result.returncode}: {log}: {output[-2000:]}")
    return output


def main() -> None:
    """Keep all vectors/builds in development areas and preserve each prior run."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--icarus-home", type=Path, default=FPGA / "build/ov5640_pwm_20261012/tools/iverilog/app/bin")
    parser.add_argument("--baseline", action="store_true", help="also benchmark one packet bank")
    args = parser.parse_args()
    home = args.icarus_home.resolve()
    run = FPGA / "build/network_control_20261012" / datetime.now().strftime("regression_%Y%m%d_%H%M%S_%f")
    run.mkdir(parents=True)
    suffix = ".exe" if sys.platform == "win32" else ""
    compiler, engine = str(home / ("iverilog"+suffix)), str(home / ("vvp"+suffix))
    vectors(FPGA / "sim/vectors/network_control")
    for path in (FPGA / "sim/vectors/network_control").glob("*.hex"):
        shutil.copyfile(path, run / path.name)
    sources = [FPGA / 'rtl/memory/frame_manager_pkg.sv'] + sorted((FPGA / "rtl/network").glob("*.sv")) + sorted((FPGA / "rtl/control").glob("*.sv"))
    sources += [FPGA / "rtl/memory/dma_byte_unpack.v"]
    benches = [FPGA / f"sim/tb_{name}.sv" for name in CASES]
    tracked = sources + benches + [Path(__file__), FPGA / "scripts/network_control_vectors.py",
        ROOT / "host/src/mcu_pose_v2.py", ROOT / "host/src/pango_video/protocol.py", ROOT / "mcu/tests/vectors.json"]
    manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    (run / "source_hashes.json").write_text(json.dumps(manifest, indent=2)+"\n")
    command([compiler, "-V"], run, "compiler_version.log", 30)
    results = {}
    for name in CASES:
        image = str(run / f"{name}.vvp")
        command([compiler, "-g2012", "-s", f"tb_{name}", "-o", image, *map(str, sources),
                 str(FPGA / f"sim/tb_{name}.sv")], run, f"{name}.compile.log", 60)
        output = command([engine, image], run, f"{name}.log", 600)
        if f"{name.upper()}_PASS" not in output or "FATAL" in output:
            raise RuntimeError(f"missing PASS: {name}")
        results[name] = True
        print(f"{name}: PASS", flush=True)
    network = verify_wire(run)
    (run / "network_result.json").write_text(json.dumps(network, indent=2)+"\n")
    # Independent host receiver regressions include reordering/duplicate/loss,
    # deadlines and immutable identity. Existing transport tests use localhost
    # UDP loopback with synthetic bytes, never a board IP or actual UART.
    host_tests = ["test_mcu_pose_v2", "test_mcu_v2_stream", "test_transport"]
    command([sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "host/tests"),
             "-p", "test_mcu*py"], run, "host_mcu.log", 60)
    command([sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "host/tests"),
             "-p", "test_transport.py"], run, "host_transport.log", 120)
    if args.baseline:
        baseline = run / "single_bank"
        baseline.mkdir()
        shutil.copyfile(run / "arp_reply.hex", baseline / "arp_reply.hex")
        command([compiler, "-g2012", "-s", "tb_raw_network", "-Ptb_raw_network.BANKS=1", "-o", str(baseline / "raw_network.vvp"),
                 *map(str, sources), str(FPGA / "sim/tb_raw_network.sv")], baseline, "compile.log", 60)
        command([engine, str(baseline / "raw_network.vvp")], baseline, "simulation.log", 600)
        comparison = verify_wire(baseline)
        (baseline / "network_result.json").write_text(json.dumps(comparison, indent=2)+"\n")
    summary = dict(passed=True, cases=results, network=network, host_tests=host_tests,
                   hardware_tested=False, programmed=False, pnr_tested=False)
    (run / "result.json").write_text(json.dumps(summary, indent=2)+"\n")
    print(f"NETWORK_CONTROL_REGRESSION_PASS {run}", flush=True)


if __name__ == "__main__":
    main()
