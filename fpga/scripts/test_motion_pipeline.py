"""Run retained C3/C5/C6 and explicit C4 withdrawal tests through the frozen Verilator flow.

The existing runner records immutable source hashes and software-only results.
No PDS lock, hardware programming, or physical calibration is touched.
"""
from pathlib import Path
import subprocess
import sys


def main():
    """Stop on the first failed compiler/test, preserving its original evidence."""
    runner=Path(__file__).with_name("sim_video_verilator.py")
    for top in ("tb_motion_algorithms","tb_motion_config","tb_history_geometry","tb_frame_runtime_actions","tb_runtime_history_actions","tb_encoder_pose_model","tb_viewport_bounds"):
        completed=subprocess.run([sys.executable,str(runner),"--motion-test",top,"--build-jobs","4"],
                                 creationflags=0x08000000)
        if completed.returncode:
            return completed.returncode
    return 0


if __name__=="__main__":sys.exit(main())
