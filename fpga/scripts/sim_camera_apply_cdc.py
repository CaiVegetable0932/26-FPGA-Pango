"""Freeze camera mailbox, SCCB startup and asynchronous request evidence; no PDS."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    """Test clock ratios, held payload, rejection, sensor readback and reset abort."""
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / "build/mcu_link_20261023" / datetime.now().strftime("camera_cdc_%Y%m%d_%H%M%S_%f")
    source = run / "source"
    source.mkdir(parents=True)
    names = ["rtl/memory/processing_job_cdc.sv", "rtl/input/ov5640_integrated_startup.v",
        "rtl/input/ov5640_exposure_update.sv", "rtl/input/ov5640_group_exposure.sv",
        "rtl/input/ov5640_reference_profile.v", "rtl/input/ov5640_raw8_mode.v",
        "rtl/input/ov5640_register_service.v", "rtl/mini_camera_diag/vendor/camera/SCCB.v",
        "rtl/mini_camera_diag/vendor/camera/data_init.v", "sim/ov5640_sccb_model.sv",
        "sim/tb_ov5640_integrated_startup.sv", "sim/tb_camera_apply_cdc.sv"]
    hashes = {}
    for name in names:
        data = (fpga / name).read_bytes()
        (source / Path(name).name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    # Bind the constraint change and runner without pretending simulation proves
    # physical delay or that native synthesis preserves the capture endpoints.
    for name in ("constraints/video_system/clocks_cdc.fdc", "scripts/sim_camera_apply_cdc.py"):
        data = (fpga / name).read_bytes()
        (run / Path(name).name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    (run / "sources.json").write_text(json.dumps(hashes, indent=2))
    tool = fpga / "build/ov5640_pwm_20261012/tools/iverilog/app/bin"
    jobs = [("baseline", "tb_ov5640_integrated_startup", None),
        ("ddr125_clk27", "tb_camera_apply_cdc", (4, 18.5185, .7)),
        ("phase_shift", "tb_camera_apply_cdc", (4, 18.5185, 13.1)),
        ("reverse_ratio", "tb_camera_apply_cdc", (19.1, 4.3, 2.3))]
    result = dict(passed=False, pds_executed=False, hardware_tested=False, tests=[])
    try:
        for label, top, clocks in jobs:
            opts = [] if clocks is None else [f"-P{top}.{key}={value}" for key, value in zip(
                ("SOURCE_HALF", "TARGET_HALF", "TARGET_PHASE"), clocks)]
            binary = run / (label + ".vvp")
            commands = [[str(tool / "iverilog.exe"), "-g2012", "-s", top, *opts, "-o", str(binary),
                *[str(source / Path(n).name) for n in names]], [str(tool / "vvp.exe"), str(binary)]]
            for phase, command in zip(("compile", "run"), commands):
                (run / f"{label}.{phase}.command.json").write_text(json.dumps(command))
                # The packaged Windows Icarus requires a real stdin pipe.
                out = subprocess.run(command, cwd=source, input="", capture_output=True, text=True, timeout=60)
                log = out.stdout + out.stderr
                (run / f"{label}.{phase}.log").write_text(log)
                if out.returncode or (phase == "run" and "_PASS" not in log):
                    raise RuntimeError(f"{label}/{phase}: {log}")
            result["tests"].append(dict(test=label, passed=True, clocks=clocks))
            print(label, "PASS", flush=True)
        result["passed"] = True
    finally:
        result["sources_intact"] = all(hashlib.sha256((fpga / n).read_bytes()).hexdigest() == h for n, h in hashes.items())
        result["passed"] &= result["sources_intact"]
        (run / "result.json").write_text(json.dumps(result, indent=2))
        print("CAMERA_CDC_EVIDENCE", run, flush=True)
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
