"""Check CCR failure visibility and generated PG2L100H electrical attributes."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from constraint_report import read_constraint_report

FPGA = Path(__file__).resolve().parents[1]


class ConstraintReportTests(unittest.TestCase):
    """Unknown, truncated and erroneous reports must never look reviewed."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=FPGA / 'build', prefix='ccr_test_')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'check.ccr'

    def parse(self, summary, details=''):
        self.path.write_text(summary + '\n' + details, encoding='utf-8')
        return read_constraint_report(self.path)

    def test_missing_and_unrecognized(self):
        result = read_constraint_report(self.path)
        self.assertFalse(result['available'])
        self.assertIsNone(result['errors'])
        self.assertTrue(result['requires_review'])
        self.assertFalse(self.parse('incomplete native output')['summary_valid'])

    def test_clean(self):
        result = self.parse('Found 0 error(s), 0 critical warning(s), 0 warning(s), out of 12 constraint(s)')
        self.assertTrue(result['summary_valid'])
        self.assertFalse(result['requires_review'])

    def test_mixed_severity_and_unknown_code(self):
        result = self.parse('Found 1 error(s), 1 critical warning(s), 1 warning(s), out of 12 constraint(s)',
                            'E: ConstraintEditor-1001: invalid\n'
                            '\tC: ConstraintEditor-2002: shared pin\n'
                            'W: FutureCode-9999: retain this diagnostic\n')
        self.assertTrue(result['summary_valid'])
        self.assertEqual(result['errors'], 1)
        self.assertEqual(len(result['diagnostics']), 3)
        self.assertEqual(result['diagnostic_counts']['FutureCode-9999'], 1)
        self.assertTrue(result['requires_review'])

    def test_truncated(self):
        result = self.parse('Found 0 error(s), 1 critical warning(s), 0 warning(s), out of 12 constraint(s)')
        self.assertFalse(result['summary_valid'])
        self.assertTrue(result['requires_review'])

    def test_real_baseline(self):
        # Read immutable pre-repair evidence: classification must match its header.
        baseline = FPGA / 'build/full_integration_20261013/board_20261022_210425_587876/constraint_check/constraint_check.ccr'
        result = read_constraint_report(baseline)
        self.assertTrue(result['summary_valid'])
        self.assertEqual(result['critical_warnings'], 61)
        self.assertEqual(result['diagnostic_counts'], {'ConstraintEditor-2002': 33, 'ConstraintEditor-2009': 28})
        self.assertTrue(result['requires_review'])

    def test_generator_in_isolation(self):
        # Run a copy under fpga/build so generation cannot overwrite live inputs.
        root = Path(self.temp.name)
        (root / 'scripts').mkdir()
        (root / 'config').mkdir()
        shutil.copyfile(FPGA / 'scripts/prepare_constraints.py', root / 'scripts/prepare_constraints.py')
        shutil.copyfile(FPGA / 'config/board.json', root / 'config/board.json')
        subprocess.run([sys.executable, str(root / 'scripts/prepare_constraints.py')], check=True)
        content = (root / 'constraints/board_pins.fdc').read_text()
        hdmi = re.findall(r'define_attribute \{p:(hdmi_[^}]+)\} \{PAP_IO_DRIVE\} \{5\}', content)
        self.assertEqual(len(hdmi), 8)
        self.assertNotRegex(content, r'\{p:hdmi_[^}]+\} \{PAP_IO_SLEW\}')
        self.assertIn('{p:status_led} {PAP_IO_SLEW} {SLOW}', content)


if __name__ == '__main__':
    unittest.main()
