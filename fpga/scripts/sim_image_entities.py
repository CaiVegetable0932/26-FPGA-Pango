"""Freeze and verify image entities, real RGB LUTs and the SCCB sensor model."""
from datetime import datetime
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    """Keep every source and log under FPGA build; never touch hardware/PDS."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true", help="Freeze sources for a separate execution step")
    parser.add_argument("--reuse-snapshot", type=Path, help="Run an existing immutable snapshot after hash verification")
    options = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    run = options.reuse_snapshot.resolve() if options.reuse_snapshot else fpga / "build/adaptive_image_20261021" / datetime.now().strftime("run_%Y%m%d_%H%M%S_%f")
    if not run.is_relative_to(fpga / "build"):
        parser.error("snapshot must be under fpga/build")
    source = run / "source"
    source.mkdir(parents=True, exist_ok=bool(options.reuse_snapshot))
    names = [
        "rtl/geometry/tone_entity_control.sv", "rtl/geometry/tone_builtin_lut.sv",
        "rtl/geometry/rgb_enhance.sv", "rtl/geometry/gamma_lut_bank.sv",
        "rtl/geometry/rgb_bilinear.sv", "rtl/isp/isp_colour_control.sv",
        "rtl/isp/rgb_colour_matrix.sv", "rtl/input/camera_brightness_control.sv",
        "rtl/input/ov5640_group_exposure.sv", "rtl/input/ov5640_exposure_update.sv", "rtl/input/ov5640_integrated_startup.v",
        "rtl/input/ov5640_reference_profile.v", "rtl/input/ov5640_raw8_mode.v",
        "rtl/input/ov5640_register_service.v", "rtl/mini_camera_diag/vendor/camera/SCCB.v",
        "rtl/mini_camera_diag/vendor/camera/data_init.v", "sim/ov5640_sccb_model.sv",
        "sim/tb_image_entities.sv", "sim/tb_image_manual_profile.sv", "sim/tb_camera_brightness_control.sv",
        "sim/tb_ov5640_integrated_startup.sv", "sim/tb_ov5640_group_exposure.sv", "sim/tb_camera_group_policy.sv", "sim/tb_pc_tone_gateway.sv",
        "rtl/control/pc_video_boot.sv", "rtl/control/pc_reference_upload.sv",
        "rtl/control/parameter_entity_guard.sv", "rtl/control/uart_8n1.sv", "rtl/control/uart_v2_parser.sv",
    ]
    hashes = {}
    if options.reuse_snapshot:
        hashes = json.loads((run / "sources.json").read_text())
        for name, expected in hashes.items():
            if hashlib.sha256((source / Path(name).name).read_bytes()).hexdigest() != expected:
                raise RuntimeError("snapshot source changed: " + name)
    else:
        for name in names:
            data = (fpga / name).read_bytes()
            target = source / Path(name).name
            target.write_bytes(data)
            hashes[name] = hashlib.sha256(data).hexdigest()
        (run / "sources.json").write_text(json.dumps(hashes, indent=2))
    if options.prepare_only:
        print("IMAGE_ENTITY_SNAPSHOT", run)
        return
    binary = fpga / "build/ov5640_pwm_20261012/tools/iverilog/app/bin"
    results = []
    # Cover both default automatic/upload capabilities and the explicit manual
    # profile so area-specialized builds retain real manual source semantics.
    for top in ("tb_image_entities", "tb_image_manual_profile", "tb_isp_colour_entity", "tb_camera_brightness_control", "tb_ov5640_integrated_startup", "tb_ov5640_group_exposure", "tb_camera_group_policy", "tb_pc_tone_gateway"):
        commands = [
            [str(binary / "iverilog.exe"), "-g2012", "-s", top, "-o", str(run / f"{top}.vvp"), *[p.name for p in source.iterdir()]],
            [str(binary / "vvp.exe"), str(run / f"{top}.vvp")],
        ]
        passed = True
        for phase, command in zip(("compile", "run"), commands):
            (run / f"{top}.{phase}.command.json").write_text(json.dumps(command))
            # This bundled Windows Icarus requires a valid pipe for stdin.
            # Inheriting the noninteractive desktop handle or NUL crashes it.
            completed = subprocess.run(command, cwd=source, input="", capture_output=True, text=True, timeout=60)
            output = completed.stdout + completed.stderr
            (run / f"{top}.{phase}.log").write_text(output)
            if completed.returncode or (phase == "run" and "_PASS" not in output):
                passed = False
                print(top, phase, completed.returncode, output)
                break
        results.append({"test": top, "passed": passed})
    passed = all(item["passed"] for item in results)
    (run / "result.json").write_text(json.dumps({"passed": passed, "tests": results,
        "hardware_tested": False, "pds_timing_tested": False, "exposure_frame_mapping_verified": False}, indent=2))
    print("IMAGE_ENTITY_REGRESSION", "PASS" if passed else "FAIL", run)
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
