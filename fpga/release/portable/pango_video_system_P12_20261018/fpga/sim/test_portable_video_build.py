"""Exercise the portable driver's bitgen safety gates with a fake native tool.

These tests do not validate PDS or hardware. They verify that a failed route,
failed min/max report or changed database cannot reach the bitgen helper.
"""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


FPGA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FPGA / 'scripts'))
import portable_video_build as driver


class BitgenGateTests(unittest.TestCase):
    """Use tiny source-bound packages and deterministic native outcomes."""

    def exercise(self, scenario):
        """Return the fake bitgen count and saved result for one scenario."""
        parent = FPGA / 'build/portable_driver_gate_tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='case ', dir=parent) as temporary:
            root = Path(temporary)
            files = {
                'fpga/source/rtl/top.v': b'module pango_video_system; endmodule\n',
                'fpga/project/flow.template.tcl':
                    b'set_dir -impl_directory {@RUN@}\n' + driver.ARCH.encode() +
                    b'add_design {@RUN@/source/rtl/top.v}\ncompile -top_module pango_video_system\n',
                'fpga/checkpoints/device_map/pango_video_system_map.adf': b'mapped',
                'fpga/checkpoints/device_map/pango_video_system.pcf': b'physical',
                'tool/bin/pds_shell.exe': b'fake test tool',
            }
            files['fpga/project/sources.json'] = json.dumps({
                'rtl/top.v': hashlib.sha256(files['fpga/source/rtl/top.v']).hexdigest()
            }).encode()
            for name, data in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            (root / 'manifest.json').write_text(json.dumps({'files': {
                n: {'sha256': hashlib.sha256(b).hexdigest()} for n, b in files.items()
            }}))
            calls = []

            def fake_native(shell, run, args, label, env):
                """Model only observable native outputs needed by the gate."""
                (run / (label + '.log')).write_text('fake native\n')
                if label == 'tool_help':
                    return 'Version 2022.2-SP6.4 build 146967 -planning_before_place -input_db_file'
                if label == 'create_project':
                    (run / 'flow.pds').write_text('fake project')
                if label == 'place_route':
                    if scenario == 'route_failed':
                        raise RuntimeError('fake congestion failure')
                    path = run / 'place_route/pango_video_system_pnr.adf'
                    path.parent.mkdir()
                    path.write_bytes(b'routed')
                if label == 'timing':
                    path = run / 'report_timing/pango_video_system.rtr'
                    path.parent.mkdir()
                    path.write_text('Design Summary : ' + (
                        'Constraints Not Met.' if scenario == 'timing_failed' else 'All Constraints Met.'))
                    if scenario == 'database_changed':
                        (run / 'place_route/pango_video_system_pnr.adf').write_bytes(b'changed')
                return ''

            def fake_bitgen(run, shell, log):
                """Count a bitgen attempt without launching an actual tool."""
                calls.append(run)
                log.write_text('fake bitgen\n')
                path = run / 'generate_bitstream/pango_video_system.sbit'
                path.parent.mkdir()
                path.write_bytes(b'FAKE TEST BITSTREAM')
                return types.SimpleNamespace(returncode=0)

            argv = ['portable_video_build.py', '--package', str(root), '--mode', 'route-map',
                    '--pds-home', str(root / 'tool')]
            module = types.SimpleNamespace(generate_from_timed_database=fake_bitgen)
            with patch.object(sys, 'argv', argv), patch.object(driver, 'native', fake_native), \
                    patch.dict(sys.modules, {'native_bitgen': module}), contextlib.redirect_stdout(io.StringIO()):
                if scenario == 'pass':
                    driver.main()
                else:
                    with self.assertRaises(RuntimeError):
                        driver.main()
            result_file = next((root / 'fpga/build').glob('*/result.json'))
            return len(calls), json.loads(result_file.read_text())

    def test_route_failure_blocks_bitgen(self):
        """Native congestion failure must stop before timing or bitgen."""
        count, result = self.exercise('route_failed')
        self.assertEqual(count, 0)
        self.assertFalse(result['passed'])

    def test_timing_failure_blocks_bitgen(self):
        """A failed timing summary must never yield a bitstream attempt."""
        count, result = self.exercise('timing_failed')
        self.assertEqual(count, 0)
        self.assertFalse(result['bitstream_generated'])

    def test_changed_database_blocks_bitgen(self):
        """Passing text cannot qualify a different routed database."""
        count, result = self.exercise('database_changed')
        self.assertEqual(count, 0)
        self.assertFalse(result['passed'])

    def test_unchanged_timed_database_reaches_bitgen(self):
        """A relocated package with spaces can reach the helper after gates."""
        count, result = self.exercise('pass')
        self.assertEqual(count, 1)
        self.assertTrue(result['passed'])
        self.assertTrue(result['bitstream_generated'])
        self.assertFalse(result['download_approved'])


if __name__ == '__main__':
    unittest.main()
