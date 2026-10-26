"""用途：核验 MINI 摄像头工程闭包、PG2L100H IP 目标与引脚碰撞；不放行硬件。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def audit(fpga):
    """解析现有 Tcl 原生清单并检查依赖只来自 FPGA 开发区，保持官方目录只读。"""
    issues, inputs, ips = [], [], []
    tcl = fpga / 'project/mini_camera_diag/mini_camera_diag.tcl'
    text = tcl.read_text(encoding='utf-8-sig')
    for kind, words in re.findall(r'(add_design|add_constraint) \[file join \$fpga_root ([^\]]+)\]', text):
        path = fpga.joinpath(*words.split()).resolve()
        if not path.is_relative_to(fpga) or not path.is_file():
            issues.append(f'missing or external input: {path}')
            continue
        inputs.append({'kind': kind, 'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
        if path.suffix == '.idf':
            doc = ET.parse(path)
            for key, value in {'family': 'Logos2', 'device': 'PG2L100H', 'package': 'FBG676', 'speedgrade': '-6'}.items():
                if doc.findtext('header/' + key) != value:
                    issues.append(f'IP target mismatch: {path.name} {key}')
            for entry in doc.findall('file_list/source/file'):
                dep = (path.parent / entry.attrib['pathname']).resolve()
                if not dep.is_relative_to(fpga) or not dep.is_file():
                    issues.append(f'missing or external IP source: {dep}')
            ips.append(str(path.relative_to(fpga)))
    # 复用现有 MINI 审核口径；碰撞通过不表示引脚电平、板卡实物已经验收。
    pins = {}
    for name in ['constraints/mini_camera_diag/board_pins.fdc', 'constraints/ddr_board_pins.fdc']:
        for port, pin in re.findall(r'define_attribute\s+\{p:([^}]+)\}\s+\{PAP_IO_LOC\}\s+\{([^}]+)\}', (fpga / name).read_text(encoding='utf-8-sig')):
            if port in pins:
                issues.append(f'duplicate port: {port}')
            pins[port] = pin
    if len(pins.values()) != len(set(pins.values())):
        issues.append('physical pin collision')
    project = (fpga / 'project/mini_camera_diag/mini_camera_diag.pds').read_text(encoding='utf-8-sig')
    # 原生清单必须覆盖全部 Tcl 设计文件，包括同时进行的其他开发改动。
    for source in [Path(item['path']).name for item in inputs if item['kind'] == 'add_design']:
        if source not in project:
            issues.append(f'generated project lacks {source}')
    if '(_option prj_impl_dir (_string "../../build/mini_camera_diag/implementation"))' not in project:
        issues.append('generated project output directory differs from existing build flow')
    return {'passed': not issues, 'issues': issues, 'input_count': len(inputs), 'ips': ips,
            'pin_count': len(pins), 'inputs': inputs, 'hardware_verified': False, 'timing_verified': False}


def main():
    """将源文件哈希和审核结果保存到指定 FPGA 构建目录，不触及生成 IP。"""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = audit(Path(__file__).resolve().parents[1])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"OV5640_PROJECT_AUDIT {'PASS' if result['passed'] else 'FAIL'} inputs={result['input_count']} pins={result['pin_count']}")
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
