"""用途：验证 PLL/分数行量化、20位范围、帧余量、缺失输入与证据标记。"""
import sys
from pathlib import Path
import unittest
from fractions import Fraction
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'model'))
from ov5640_pwm_exposure import build_plan, exposure_candidate, timing_clock, encode_exposure_ns


class ExposureTests(unittest.TestCase):
    # 全部为合成输入，不能作为本机模组的时钟/光学测量证据。
    def inputs(self):
        return {'evidence_kind': 'synthetic_test_vector', 'xclk_hz': 24_000_000,
                'pwm_hz': 150, 'registers': {'3034': 0x1a, '3035': 0x11,
                '3036': 0x3c, '3037': 0x13, '3039': 0, '3108': 1,
                '380c': 9, '380d': 0xc0, '380e': 4, '380f': 0xc8}}

    def test_pll_and_evidence(self):
        plan = build_plan(self.inputs())
        self.assertEqual(plan['timing_clock_hz_calculated'], 48_000_000)
        self.assertEqual(plan['calculated_row_ns'], 52_000)
        self.assertFalse(plan['hardware_verified'])
        self.assertEqual(plan['row_basis'], 'pll_prediction_unverified')
        self.assertIsNone(plan['source_frame_identity'])
        self.assertEqual([c['exposure_code'] for c in plan['candidates']], [2051, 4103, 6154, 8205])

    def test_hts_debug_bits_do_not_change_row_time(self):
        inputs = self.inputs()
        inputs['registers']['380c'] |= 0xe0
        self.assertEqual(build_plan(inputs)['calculated_row_ns'], 52_000)

    def test_independent_rounding_and_register_encoding(self):
        one = exposure_candidate(52_000, 150, 1, 1224)
        two = exposure_candidate(52_000, 150, 2, 1224)
        self.assertNotEqual(two['exposure_code'], one['exposure_code'] * 2)
        self.assertEqual(two['registers'], {'3500': '0x00', '3501': '0x10', '3502': '0x07'})
        self.assertLessEqual(abs(two['error_ns']), 52_000 / 32)

    def test_fractional_half_rounds_up(self):
        result = exposure_candidate(32_000_000, 1, 1, 100)
        self.assertEqual(result['exposure_code'], 500)
        result = exposure_candidate(Fraction(32_000_000_000, 1001), 1, 1, 100)
        self.assertEqual(result['exposure_code'], 501)

    def test_frame_margin_and_60fps_limit(self):
        with self.assertRaises(ValueError):
            exposure_candidate(20_000, 150, 3, 833)
        with self.assertRaises(ValueError):
            exposure_candidate(1, 150, 1, 65535)
        for row, pwm, vts, margin in [(0, 150, 1224, 4), (52_000, 0, 1224, 4),
                                      (52_000, 150, 4, 4), (52_000, 150, 1224, 0)]:
            with self.assertRaises(ValueError):
                exposure_candidate(row, pwm, 1, vts, margin)

    def test_exact_20bit_upper_bound(self):
        code = encode_exposure_ns(1_000_000_000, Fraction(16_000_000_000, 0xfffff))
        self.assertEqual(code, 0xfffff)
        with self.assertRaises(ValueError):
            encode_exposure_ns(1_000_000_000, Fraction(16_000_000_000, 0x100000))

    def test_missing_or_invalid_clock(self):
        inputs = self.inputs()
        for address,value in [('380c', 0), ('3037', 0), ('3034', 0x19), ('3039', 0x80), ('3036', 255)]:
            regs = dict(inputs['registers'])
            regs[address] = value
            if address == '380c': regs['380d'] = 0
            with self.assertRaises(ValueError): timing_clock(inputs['xclk_hz'], regs)
        with self.assertRaises(ValueError): build_plan({'pwm_hz': 150})
        with self.assertRaises(ValueError): timing_clock(None, inputs['registers'])

    def test_supplied_row_and_drift(self):
        inputs = self.inputs()
        inputs['measured_internal_row_ns'] = 52_100
        inputs['pwm_hz'] = '149.95'
        plan = build_plan(inputs)
        self.assertEqual(plan['row_basis'], 'measurement_supplied')
        self.assertEqual(plan['row_difference_ns'], 100)
        self.assertFalse(plan['optical_verified'])
        self.assertNotEqual(plan['candidates'][1]['exposure_code'], 4103)


if __name__ == '__main__':
    unittest.main()
