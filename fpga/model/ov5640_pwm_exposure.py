"""用途：按 OV5640 DVP 指南的 PLL 计算与 1/16 行编码生成 PWM 曝光候选。

只产生可审查的计算证据，不自动写寄存器，也不把名义值或模型测试当作实测。
"""
from fractions import Fraction
import argparse
import json
from pathlib import Path


def positive(value, name):
    """以有理数保留分数行和 PWM 周期，拒绝缺失/零/负输入。"""
    if value is None:
        raise ValueError(f'{name} is required')
    result = Fraction(str(value))
    if result <= 0:
        raise ValueError(f'{name} must be positive')
    return result


def timing_clock(xclk_hz, registers):
    """复现本地 DVP 指南 PDF 56-57 页算法；不支持的旁路/位模式明确拒绝。"""
    def reg(address):
        value = registers[f'{address:04x}']
        result = int(value, 0) if isinstance(value, str) else value
        if not isinstance(result, int) or not 0 <= result <= 255:
            raise ValueError(f'invalid register {address:04x}')
        return result
    xclk = positive(xclk_hz, 'xclk_hz')
    if not 6_000_000 <= xclk <= 27_000_000:
        raise ValueError('XCLK outside datasheet 6-27 MHz range')
    if reg(0x3039) & 0x80:
        raise ValueError('PLL bypass requires a separately verified clock model')
    bits = reg(0x3034) & 0x0f
    if bits not in (8, 10):
        raise ValueError('unsupported PLL bit mode')
    sysdiv = reg(0x3035) >> 4 or 16
    multiplier = reg(0x3036)
    prediv = reg(0x3037) & 0x0f
    if prediv not in (1, 2, 3, 4, 6, 8) or not multiplier:
        raise ValueError('invalid PLL predivider/multiplier')
    pll_rdiv = ((reg(0x3037) >> 4) & 1) + 1
    sclk_rdiv = 1 << (reg(0x3108) & 3)
    vco = xclk * multiplier / prediv
    if vco > 800_000_000:
        raise ValueError('VCO exceeds datasheet 800 MHz ceiling')
    sysclk = vco / sysdiv / pll_rdiv * 2 / (bits // 2) / sclk_rdiv
    # HTS高字节仅[4:0]有效，保留debug位不能被当作行时钟单位。
    hts = ((reg(0x380c) & 0x1f) << 8) | reg(0x380d)
    vts = (reg(0x380e) << 8) | reg(0x380f)
    if not hts or not vts:
        raise ValueError('HTS and VTS must be nonzero')
    return sysclk, hts, vts


def encode_exposure_ns(target_ns, row_ns):
    """独立检查 20 位编码；帧长限制由候选函数另行检查。"""
    target = positive(target_ns, 'target_ns')
    row = positive(row_ns, 'row_ns')
    raw = 16 * target / row
    code = (2 * raw.numerator + raw.denominator) // (2 * raw.denominator)
    if not 1 <= code <= 0xfffff:
        raise ValueError('exposure outside 20-bit encoding')
    return code


def exposure_candidate(row_ns, pwm_hz, periods, vts, margin=4):
    """每个完整 N 周期独立舍入，避免先舍入一周期再乘 N 的累计误差。"""
    row = positive(row_ns, 'row_ns')
    pwm = positive(pwm_hz, 'pwm_hz')
    if not isinstance(periods, int) or periods < 1:
        raise ValueError('periods must be a positive integer')
    if not isinstance(vts, int) or not 1 <= vts <= 65535:
        raise ValueError('VTS outside 16-bit register range')
    if not isinstance(margin, int) or margin < 1 or vts <= margin:
        raise ValueError('positive VTS margin must leave exposure room')
    target = Fraction(1_000_000_000) * periods / pwm
    code = encode_exposure_ns(target, row)
    if code > (vts - margin) * 16:
        raise ValueError('exposure exceeds VTS margin; frame extension forbidden')
    actual = code * row / 16
    return {'periods': periods, 'target_ns': float(target), 'exposure_code': code,
            'registers': {'3500': f'0x{(code >> 16) & 15:02x}',
                          '3501': f'0x{(code >> 8) & 255:02x}',
                          '3502': f'0x{code & 255:02x}'},
            'actual_ns': float(actual), 'error_ns': float(actual - target),
            'period_error_fraction': float((actual - target) / (target / periods))}


def build_plan(inputs):
    """保留计算输入与来源状态，候选越界逐档报告；不宣称传感器实际响应已验证。"""
    registers = inputs.get('registers')
    if not registers:
        raise ValueError('register readback is required; do not use vendor constants as evidence')
    clock, hts, vts = timing_clock(inputs.get('xclk_hz'), registers)
    calculated_row = Fraction(hts * 1_000_000_000) / clock
    measured_row = inputs.get('measured_internal_row_ns')
    row = positive(measured_row, 'measured_internal_row_ns') if measured_row is not None else calculated_row
    result = {'inputs': inputs, 'timing_clock_hz_calculated': float(clock), 'hts': hts, 'vts': vts,
              'calculated_row_ns': float(calculated_row), 'used_row_ns': float(row),
              'row_basis': 'measurement_supplied' if measured_row is not None else 'pll_prediction_unverified',
              'row_difference_ns': float(row - calculated_row),
              'hardware_verified': False, 'optical_verified': False,
              'source_frame_identity': None, 'pairing_status': 'unverified', 'candidates': []}
    for n in inputs.get('periods', [1, 2, 3, 4]):
        try:
            candidate = exposure_candidate(row, inputs.get('pwm_hz'), n, vts, inputs.get('vts_margin', 4))
            candidate['eligible_by_calculation'] = True
        except ValueError as error:
            candidate = {'periods': n, 'eligible_by_calculation': False, 'reason': str(error)}
        result['candidates'].append(candidate)
    return result


def main():
    """显式输入/输出路径；仅保存计算 JSON，不改工程或摄像头配置。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    inputs = json.loads(args.input.read_text(encoding='utf-8-sig'))
    result = build_plan(inputs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
