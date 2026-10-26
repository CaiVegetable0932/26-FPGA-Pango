"""用途：02不可暂停输入FIFO容量预算，区分服务停顿/CDC余量和标记打包开销。"""
import argparse
import json
from fractions import Fraction
from pathlib import Path


def budget(pclk_hz, stall_ns, fifo_entries, entry_bits, cdc_margin=4, pipeline_entries=2, marker_entries=0):
    """一拍最多一RAW字节，先按峰值停顿算entry；平均62.208MB/s不能代替峰值。"""
    rate = Fraction(str(pclk_hz))
    stall = Fraction(str(stall_ns))
    if rate <= 0 or stall < 0 or not isinstance(fifo_entries, int) or fifo_entries < 1:
        raise ValueError('positive PCLK/depth and nonnegative service stall are required')
    if entry_bits < 8 or cdc_margin < 2 or pipeline_entries < 0 or marker_entries < 0:
        raise ValueError('invalid entry width, CDC margin or marker/pipeline reserve')
    arrivals = rate * stall / 1_000_000_000
    stalled_entries = (arrivals.numerator + arrivals.denominator - 1) // arrivals.denominator
    reserve = cdc_margin + pipeline_entries + marker_entries
    required = stalled_entries + reserve
    memory_bits = entry_bits * fifo_entries
    return {'pclk_hz_assumed': float(rate), 'service_stall_ns': float(stall),
            'stalled_entries': stalled_entries, 'reserved_entries': reserve, 'required_entries': required,
            'fifo_entries': fifo_entries, 'entry_bits_including_markers': entry_bits,
            'capacity_covers_stall': required <= fifo_entries,
            'available_stall_ns': float(max(0, fifo_entries - reserve) * 1_000_000_000 / rate),
            'memory_bits': memory_bits, 'minimum_36k_blocks_by_bits': (memory_bits + 36863) // 36864,
            'hardware_verified': False, 'cdc_verified': False,
            'scope': 'finite service bound only; native FIFO width/depth packing still requires IP mapping'}


def main():
    """显式输出路径；保留预算作为计算值，不生成/改写原生FIFO配置。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--pclk-hz', required=True)
    parser.add_argument('--stall-ns', required=True)
    parser.add_argument('--fifo-entries', type=int, required=True)
    parser.add_argument('--entry-bits', type=int, required=True)
    parser.add_argument('--marker-entries', type=int, default=0)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = budget(args.pclk_hz, args.stall_ns, args.fifo_entries, args.entry_bits, marker_entries=args.marker_entries)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
