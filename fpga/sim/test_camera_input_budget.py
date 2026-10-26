"""用途：峰值容量、舍入、元数据内存开销与非法输入回归，不把预算当实测。"""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'model'))
from camera_input_budget import budget


class InputBudgetTests(unittest.TestCase):
    def test_peak_not_average(self):
        result = budget(96_000_000, 20_000, 2048, 8)
        self.assertEqual(result['required_entries'], 1926)
        self.assertTrue(result['capacity_covers_stall'])
        self.assertFalse(result['hardware_verified'])
        self.assertAlmostEqual(result['available_stall_ns'], 21270.833333, places=5)

    def test_service_overrun(self):
        self.assertFalse(budget(96_000_000, 30_000, 2048, 8)['capacity_covers_stall'])
        self.assertTrue(budget(96_000_000, 30_000, 4096, 8)['capacity_covers_stall'])

    def test_fractional_arrival_ceil(self):
        self.assertEqual(budget(100_000_000, 1, 64, 8)['required_entries'], 7)
        self.assertEqual(budget(100_000_000, 0, 64, 8)['required_entries'], 6)

    def test_tags_are_not_free(self):
        bare = budget(96_000_000, 20_000, 2048, 8)
        tagged = budget(96_000_000, 20_000, 2048, 208)
        self.assertEqual(tagged['memory_bits'], bare['memory_bits'] * 26)
        self.assertEqual(tagged['minimum_36k_blocks_by_bits'], 12)
        self.assertGreater(budget(96_000_000, 20_000, 2048, 8, marker_entries=1082)['required_entries'], 2048)

    def test_invalid_inputs(self):
        for args in [(0, 1, 2048, 8), (1, -1, 2048, 8), (1, 1, 0, 8), (1, 1, 2048, 7)]:
            with self.assertRaises(ValueError):
                budget(*args)


if __name__ == '__main__':
    unittest.main()
