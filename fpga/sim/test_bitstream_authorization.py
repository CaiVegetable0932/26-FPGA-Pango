"""Prove the pre-bitstream delivery boundary without invoking native PDS."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import native_bitgen


class BitstreamAuthorizationTests(unittest.TestCase):
    """Passing physical prerequisites alone must not authorize generation."""
    def test_false_missing_or_truthy_nonboolean_refused_before_artifacts(self):
        root = Path(__file__).resolve().parents[1] / 'build/mcu_link_20261023/bitgen_gate_tests'
        root.mkdir(parents=True, exist_ok=True)
        ready = dict(design_complete=True, selected_source_simulation_passed=True,
                     resource_and_constraints_reviewed=True, whole_design_route_allowed=True)
        for extra in ({'bitstream_generation_allowed': False}, {},
                      {'bitstream_generation_allowed': 'true'}, {'bitstream_generation_allowed': 1}):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory(dir=root) as temporary:
                run = Path(temporary)
                (run / 'report_timing').mkdir()
                (run / 'place_route').mkdir()
                # Valid prerequisite fixtures ensure denial is authorization,
                # not an accidentally missing route database or passing STA.
                (run / 'report_timing/pango_video_system.rtr').write_text('Design Summary : All Constraints Met.\n')
                (run / 'place_route/pango_video_system_pnr.adf').write_bytes(b'fixture routed database')
                log = run / 'bitgen.log'
                with patch.object(native_bitgen, 'require_whole_design_ready', return_value=ready | extra), \
                     patch.object(native_bitgen, 'run_supervised') as native:
                    with self.assertRaisesRegex(ValueError, 'bitstream_generation_allowed=true'):
                        native_bitgen.generate_from_timed_database(run, 'fixture-shell', log)
                    native.assert_not_called()
                self.assertFalse((run / 'bitgen_from_checkpoint.tcl').exists())
                self.assertFalse((run / 'bitgen_checkpoint.json').exists())
                self.assertFalse(log.exists())

    def test_authorization_and_timing_cannot_replace_physical_resource_evidence(self):
        """Even future authorized generation must prove its actual PR LUT use."""
        root = Path(__file__).resolve().parents[1] / 'build/mcu_link_20261023/bitgen_gate_tests'
        root.mkdir(parents=True, exist_ok=True)
        ready = dict(design_complete=True, selected_source_simulation_passed=True,
                     resource_and_constraints_reviewed=True, whole_design_route_allowed=True,
                     bitstream_generation_allowed=True)
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            run = Path(temporary)
            (run / 'report_timing').mkdir()
            (run / 'place_route').mkdir()
            (run / 'report_timing/pango_video_system.rtr').write_text('Design Summary : All Constraints Met.\n')
            (run / 'place_route/pango_video_system_pnr.adf').write_bytes(b'fixture routed database')
            # Deliberately omit the physical utilization report while all
            # previous prerequisites pass; no native call/artifact may escape.
            with patch.object(native_bitgen, 'require_whole_design_ready', return_value=ready), \
                 patch.object(native_bitgen, 'run_supervised') as native:
                with self.assertRaises(ValueError):
                    native_bitgen.generate_from_timed_database(run, 'fixture-shell', run / 'bitgen.log')
                native.assert_not_called()
            self.assertFalse((run / 'bitgen_from_checkpoint.tcl').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
