"""Summarize actual artifacts; absent reports and timing warnings never become PASS."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
from flow import ROOT, ERROR, read_text, sha


def timing_summary(directory):
    directory = directory.resolve()
    path = directory / 'report_timing/flow_smoke_top.rtr'
    if not path.is_file():
        return {'passed': False, 'reason': 'timing report missing'}
    text = read_text(path)
    pattern = r'(Setup|Hold) Summary\((Slow|Fast) Corner\):.*?\n\s*clk27\s+clk27\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)'
    corners = {f'{kind.lower()}_{corner.lower()}': {'slack_ns': float(slack), 'total_negative_slack_ns': float(tns),
               'failing_endpoints': int(failed), 'endpoints': int(total)}
               for kind, corner, slack, tns, failed, total in re.findall(pattern, text, re.S)}
    passed = len(corners) == 4 and 'Design Summary : All Constraints Met.' in text and all(
        row['slack_ns'] >= 0 and row['failing_endpoints'] == 0 and row['endpoints'] > 0 for row in corners.values())
    return {'passed': passed, 'corners': corners, 'clock_mhz': 27,
            'io_exceptions': ['rstn/key: asynchronous input to synchronizers', 'led0: LED without synchronous external receiver'],
            'all_io_has_synchronous_delays': False, 'report': str(path.relative_to(ROOT))}


def build_summary(directory):
    directory = directory.resolve()
    meta = directory / 'build_result.json'
    result = json.loads(meta.read_text(encoding='utf-8')) if meta.is_file() else {'passed': False}
    result['timing'] = timing_summary(directory)
    console = read_text(directory / 'console.log')
    result['warnings'] = sorted(set(line.strip() for line in re.findall(r'^W:.*$', console, re.M)))
    allowed = [r"^W: Loop was found during constant probe\.$",
               r"^W: Timing-4087: Port 'led0' is not constrained, it is treated as combinational output\.$",
               r"^W: Timing-4086: Port '(key|rstn)' is not constrained, it is treated as combinational input\.$"]
    result['unreviewed_warnings'] = [x for x in result['warnings'] if not any(re.fullmatch(p, x) for p in allowed)]
    result['warning_review'] = {
        'constant_probe': 'Small design contains registered counter/LED feedback. Retained warning; three functional netlist tests and four STA checks are required. No combinational feedback exists in the RTL.',
        'io_delays': 'Three explicitly excluded asynchronous/non-synchronous ports; not a waiver for internal timing or other designs.'}
    mapping = read_text(directory / 'device_map/flow_smoke_top.dmr')
    resources = {}
    for name, used, available in re.findall(r'^\|\s*(LUT|FF|DRM|APM)\s*\|\s*(\d+)\s*\|\s*(\d+)', mapping, re.M):
        resources[name] = {'used': int(used), 'available': int(available)}
    result['resources'] = resources
    result['artifact_integrity'] = all((directory / p).is_file() and sha(directory / p) == record['sha256']
                                       for p, record in result.get('artifacts', {}).items())
    result['passed'] = result.get('passed', False) and result['timing']['passed'] and not result['unreviewed_warnings'] and result['artifact_integrity']
    result['directory'] = directory.relative_to(ROOT.parent).as_posix()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--repeat-dir', type=Path, required=True)
    parser.add_argument('--tests-dir', type=Path, required=True)
    parser.add_argument('--simlib-dir', type=Path, required=True)
    args = parser.parse_args()
    builds = [build_summary(p.resolve()) for p in [args.build_dir, args.repeat_dir]]
    tests = json.loads((args.tests_dir / 'tests.json').read_text(encoding='utf-8'))
    liblog = read_text(args.simlib_dir / 'console.log')
    transcript = read_text(args.simlib_dir / 'transcript')
    libok = 'Compile libraries succeed.' in liblog and 'FLOW_SIMLIB_COMMAND_DONE' in liblog and not ERROR.search(liblog + '\n' + transcript)
    input_sets = [json.loads((p / 'inputs.json').read_text(encoding='utf-8')) for p in [args.build_dir, args.repeat_dir]]
    repeated = input_sets[0] == input_sets[1] and all(b['passed'] for b in builds)
    # Only actual PDS design inputs must match the current checkout. Report/test
    # driver revisions are recorded in each run, but do not alter PDS netlists.
    used = ['rtl/flow_smoke_top.v', 'constraints/flow_smoke.fdc', 'scripts/build.tcl',
            'sim/tb_flow_smoke.v', 'config/board.json', 'config/toolchain.json']
    normalized_inputs = {k.replace('\\', '/'): v for k, v in input_sets[0].items()}
    current_design_matches = all(normalized_inputs.get(k) == sha(ROOT / k) for k in used)
    artifacts = builds[0].get('artifacts', {})
    stages = tests.get('stages', {})
    simulation_inputs_match = set(stages) == {'rtl', 'synthesis', 'route_function', 'timing_min', 'timing_max'}
    for name, row in stages.items():
        expected = normalized_inputs['rtl/flow_smoke_top.v'] if name == 'rtl' else artifacts[
            'synthesize/flow_smoke_top_syn.vm' if name == 'synthesis' else 'generate_netlist/flow_smoke_top_sim.v']['sha256']
        simulation_inputs_match &= row.get('design_sha256') == expected and row.get('testbench_sha256') == normalized_inputs['sim/tb_flow_smoke.v']
        if name.startswith('timing_'):
            simulation_inputs_match &= row.get('sdf_sha256') == artifacts['generate_netlist/flow_smoke_top_sta.sdf']['sha256']
    repeated = repeated and current_design_matches
    hostpath = ROOT.parent / 'host/reports/pds-offline-20260907-host-tests.json'
    host = json.loads(hostpath.read_text(encoding='utf-8')) if hostpath.is_file() else {'passed': False}
    result = {'utc': datetime.now(timezone.utc).isoformat(), 'scope': 'PG2L100H minimum offline flow; not the 1080p video system',
              'status': 'PASS' if repeated and simulation_inputs_match and libok and tests['passed'] and host['passed'] else 'COMPLETED_WITH_LIMITATIONS',
              'builds': builds, 'clean_rebuild_passed': repeated, 'current_design_inputs_match': current_design_matches,
              'simulation_inputs_match': simulation_inputs_match, 'simulation': tests,
              'simulation_libraries': {'passed': libok, 'directory': str(args.simlib_dir),
                   'warnings': sorted(set(x for x in transcript.splitlines() if 'Warning:' in x))},
              'host_tests': {'passed': host['passed'], 'tests_run': host.get('tests_run'), 'hardware': False},
              'power': {'kind': 'PDS default-activity estimate only', 'measured': False},
              'hardware_programming': 'not_performed',
              'not_implemented': ['FPGA UART status protocol', 'RAW8 DVP/ISP/DDR frame pools', 'FPGA RGMII/MAC/UDP/HDMI pipeline',
                                  'geometry reference model and RTL', 'MCU firmware'],
              'notes': ['No vendor simulation model was edited; SDF negative-check warnings remain visible.',
                        'The installed ModelSim 10.1c successfully compiled the modelsim10.2c-labelled PDS libraries used here; this does not validate every IP.',
                        'Only licence locator strings in logs are redacted; diagnostic errors and warnings are retained.']}
    reports = ROOT / 'reports'
    reports.mkdir(exist_ok=True)
    (reports / 'latest.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    b = builds[0]
    rows = b['timing']['corners']
    bit = b['artifacts']['generate_bitstream/flow_smoke_top.sbit']
    labels = {'rtl':'RTL 功能仿真', 'synthesis':'综合后功能仿真', 'route_function':'布线后功能仿真', 'timing_min':'SDF min 时序仿真', 'timing_max':'SDF max 时序仿真'}
    tests_rows = '\n'.join(f"| {labels[name]} | {'通过' if row['passed'] else '功能比较通过；严格时序受限' if row.get('functional_passed') else '未通过'} | {row.get('checks', 0)} 次比较；{row.get('toggles', 0)} 次状态变化 |" for name, row in tests['stages'].items())
    text = f'''# PDS 非烧录流程验证简报

日期：2026-09-07。范围：规划 A 阶段的 PG2L100H 最小工具链验证。**已完成全部离线环节的尝试；完整视频系统尚未实现。**

## 实际结果

| 环节 | 结果 | 说明 |
| --- | --- | --- |
| 环境与许可证 | 通过 | PDS 2022.2-SP6.4 build 146967，ADS 实际综合可用；ModelSim SE-64 10.1c |
| 目标配置 | 文档核对完成 | Logos2 / PG2L100H / -6 / FBG676，D18 27 MHz；实物板版本未验证 |
| Logos2 Verilog 前仿/后仿库 | {'通过' if libok else '未通过'} | 官方命令在新目录生成，未修改厂商模型 |
| 综合、映射、布局布线、时序、网表、位流 | {'通过' if b['passed'] else '未通过'} | 全部实际执行；检查退出码、错误、完成标记及新产物 |
| 同输入空目录重建 | {'通过' if repeated else '未通过'} | 两次输入哈希一致，分别生成本次产物；不承诺含时间头位流逐字节相同 |
{tests_rows}
| 上位机软件回归 | {'通过' if host['passed'] else '未通过'} | {host.get('tests_run')} 项；仅软件与本机回环 |
| 功耗报告 | 已生成估算 | 默认翻转率与环境假设，不能作为实测功耗 |
| 烧录与板级测量 | 未执行 | 无下载器访问、无硬件验收结论 |

## 关键数字与限制

- 资源：{b['resources']['LUT']['used']} LUT / {b['resources']['FF']['used']} FF，DRM/APM 均为 0。只代表这个最小工程。
- 27 MHz 下最差 setup 裕量 **{min(rows['setup_slow']['slack_ns'], rows['setup_fast']['slack_ns']):.3f} ns**；最差 hold 裕量 **{min(rows['hold_slow']['slack_ns'], rows['hold_fast']['slack_ns']):.3f} ns**。快、慢角点违例端点均为 0。
- `rstn/key` 是异步按键，`led0` 没有同步接收器，三者有明确 false-path 理由；PDS 对缺少同步 I/O delay 的提示保留。内部路径正常计时，不能写成“所有 I/O 已设置同步延迟”。
- 延迟回标已成功，min/max 两次数据比较均正确，但官方 `V_FFSYN.v` 报 **vsim-8756：负时序检查值缺少延迟参考/数据信号模型**。因此严格门级时序仿真仍未通过，不屏蔽告警、不修改原模型；已完成的时序结论仅依据本次四组 STA，严格后仿待厂商确认兼容模型/仿真器组合。
- 编译器 `Loop was found during constant probe` 与官方库宏重定义提示保留，诊断及逐项说明见 `latest.json`。同步寄存器使用当前 ADS 官方属性保留，未推断成 LUT RAM。
- 已修正：未继承用户许可证环境、PG2L100H 封装名、仿真库枚举大小写/名称、SDF 路径引用、SCBV 选项。修正前日志保留于 `flow_20260907_a/b`、`tests_a/b` 等目录。
- 当前工程是每 32 周期翻转的离线诊断设计，**不是可交付的视频位流**。FPGA UART、DVP/ISP/DDR、RGMII/UDP/HDMI、矫正算法及 MCU 尚待实现；1080p30、吞吐、精度、长稳和功耗未验收。

## 交付与复现

- 构建目录：`{b['directory']}`；复建：`{builds[1]['directory']}`；仿真：`{args.tests_dir.as_posix()}`。
- 位流：`{b['directory']}/generate_bitstream/flow_smoke_top.sbit`，{bit['bytes']} bytes。
- 位流 SHA-256：`{bit['sha256']}`。
- 自动入口与用法：[FPGA 开发区](../README.md)。机器可读结果：[latest.json](latest.json)。原始日志只脱敏许可证路径，未隐藏失败或告警。

## 依据

安装版只读手册：PDS User Guide p.150、248-255；Simulation User Guide p.6-9；Timing Analyzer p.15-16；ADS Synthesis p.53、92、104；UCE p.74。板卡依据：MINI 硬件手册 V1.3 p.6、12-14、34-35，以及 2_7 按键 LED 示例。

SCBV 的本机选项与 [紫光同创官方 UG042003 V1.14，表 2-36](https://www.pangomicro.com/en/uploads/17503246_1729499157.pdf) 交叉核对：本最小设计未使用 L4/L5，采用 High Voltage。官方资料未被修改。
'''
    (reports / 'latest.md').write_text(text, encoding='utf-8')
    print(json.dumps({'status': result['status'], 'clean_rebuild_passed': repeated, 'simlib_passed': libok,
                      'report': str(reports / 'latest.md')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
