"""Reject unsupported SYN timing CLI execution in installed PDS 2022.2-SP6.4.

The Timing Analyzer GUI manual lists SYN DB, but the native report_timing
-input_db_file command requires a PNR DB (verified Flow-0013 on 2026-10-23).
Do not launch that command or infer post-synthesis timing from a MAP report.
The failed prototype and native evidence are archived under
fpga/build/mcu_link_20261023/post_syn_reset_overlay and
fpga/build/full_integration_20261013/postsyn_reset_probe_20261023_211906_892378.
"""
import argparse


def main():
    """Fail before any files, Tcl, subprocess or native slot are created."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True)
    parser.add_argument('--timeout-minutes', type=int, default=15)
    parser.add_argument('--dry-run', action='store_true')
    parser.parse_args()
    parser.error('SYN timing CLI unavailable: installed report_timing requires PNR DB; '
                 'GUI SYN DB support cannot be used as CLI evidence. No PDS process started.')


if __name__ == '__main__':
    main()
