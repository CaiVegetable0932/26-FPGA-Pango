"""用途：审计02专用原生内部时序与资源；不把未约束外部IO/CDC冒充通过。"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def timing_summary(path):
    """分别核验slow/fast setup/hold/recovery/removal摘要，要求无失败端点和负slack。"""
    text = path.read_text(encoding='utf-8-sig', errors='replace')
    summaries = {}
    for corner in ['Slow', 'Fast']:
        for kind in ['Setup', 'Hold', 'Recovery', 'Removal']:
            heading = f'{kind} Summary({corner} Corner):'
            if heading not in text:
                raise ValueError(f'missing {heading}')
            block = text.split(heading, 1)[1].split('====================================================================================================', 1)[0]
            match = re.search(r'^\s*input_internal_budget\s+input_internal_budget\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)', block, re.M)
            if not match:
                raise ValueError(f'unknown summary wording: {heading}')
            slack, total, failures, endpoints = match.groups()
            summaries[f'{corner.lower()}_{kind.lower()}'] = {'slack_ns': float(slack), 'total_negative_ns': float(total),
                'failing_endpoints': int(failures), 'endpoints': int(endpoints)}
    passed = 'Design Summary : All Constraints Met.' in text and all(
        row['slack_ns'] >= 0 and row['total_negative_ns'] == 0 and row['failing_endpoints'] == 0
        for row in summaries.values())
    estimated = re.search(r'input_internal_budget\s+100\.\d+ MHz\s+(\d+\.\d+) MHz', text)
    return {'internal_timing_passed': passed, 'requested_clock_hz': 100_000_000,
            'estimated_frequency_mhz': float(estimated[1]) if estimated else None, 'summaries': summaries,
            'report_path': str(path.resolve()), 'report_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'external_io_timing_verified': False, 'cdc_verified': False, 'board_timing_verified': False}


def resource_summary(path):
    """资源取实际综合报告，不混用规划预算或声称纯模块/整机资源。"""
    text = path.read_text(encoding='utf-8-sig', errors='replace')
    result = {'report_path': str(path.resolve()), 'report_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    for key, pattern in {'luts': r'Total LUTs:\s*(\d+)', 'registers': r'Total Registers:\s*(\d+)',
                         'latches': r'Total Latches:\s*(\d+)', 'drm': r'Total DRM =\s*([\d.]+)',
                         'apm': r'Total APMs =\s*([\d.]+)'}.items():
        match = re.search(pattern, text)
        if not match:
            raise ValueError(f'missing resource field {key}')
        result[key] = float(match[1]) if key in ['drm', 'apm'] else int(match[1])
    return result


def main():
    """只读原生报告并输出专用审核JSON；日志全部保留，不改变工程或例外。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / 'build/camera_input_20261012'
    result = {'timing': timing_summary(root / 'pds/report_timing/camera_input_bench.rtr'),
              'input_bench_synthesis': resource_summary(root / 'pds/synthesize/camera_input_bench.snr'),
              'control_bench_synthesis': resource_summary(root / 'control_pds/synthesize/camera_control_bench.snr'),
              'hardware_verified': False, 'source_fps_verified': False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(f"CAMERA_INPUT_INTERNAL_TIMING {'PASS' if result['timing']['internal_timing_passed'] else 'FAIL'}")
    if not result['timing']['internal_timing_passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
