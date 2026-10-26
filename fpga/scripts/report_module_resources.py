"""Extract the installed ADS hierarchy without double-counting parent modules.

SYN hierarchy is attribution evidence, not a marginal deletion estimate or STA
result. The same build's native status and source digest accompany every table.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from implementation_readiness import read_mapped_resources


def parse_hierarchy(text):
    """Reconstruct full instance paths from the ADS '+ child' indentation."""
    rows, stack = [], []
    section = text.split('Device Utilization Summary Of Each Module:', 1)[1]
    for line in section.splitlines():
        fields = line.split('|')
        if len(fields) < 7 or not fields[2].strip().isdigit():
            continue
        label = fields[1].rstrip()
        depth = (label.index('+') + 1) // 2 if '+' in label else 0
        name = label.split('+', 1)[-1].strip()
        if depth > len(stack):
            raise ValueError(f'Invalid ADS hierarchy depth at {name}')
        stack = stack[:depth] + [name]
        row = dict(path='/'.join(stack), depth=depth,
                   lut=int(fields[2]), ff=int(fields[3]), distributed_ram=int(fields[4]),
                   apm=int(fields[5]), drm=float(fields[6]))
        rows.append(row)
    if not rows or rows[0]['depth'] != 0:
        raise ValueError('No ADS root resource row')
    by_path = {row['path']: row for row in rows}
    if len(by_path) != len(rows):
        raise ValueError('Ambiguous duplicate module paths')
    for row in rows:
        children = [child for child in rows if child['path'].rsplit('/', 1)[0] == row['path'] and child['depth'] == row['depth'] + 1]
        row['own_lut'] = row['lut'] - sum(child['lut'] for child in children)
        if row['own_lut'] < 0:
            raise ValueError('ADS hierarchy does not support additive attribution')
    if sum(row['own_lut'] for row in rows) != rows[0]['lut']:
        raise ValueError('Resource attribution failed total reconciliation')
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    build = args.build.resolve()
    if not build.is_relative_to(fpga / 'build'):
        raise ValueError('Resource artifacts must stay in fpga/build')
    report = build / 'synthesize/pango_video_system.snr'
    rows = parse_hierarchy(report.read_text(errors='replace'))
    status_path = build / 'result.json'
    status = json.loads(status_path.read_text()) if status_path.exists() else {'stage': 'running', 'errors': []}
    total = rows[0]['lut']
    # SYN remains useful while MAP is absent or over budget. Only the selected
    # native MAP report can authorize routing; missing evidence is never green.
    try:
        mapped = dict(valid=True, **read_mapped_resources(build))
    except ValueError as error:
        mapped = dict(valid=False, below_70_percent=False, error=str(error))
    evidence = dict(report=str(report), report_sha256=hashlib.sha256(report.read_bytes()).hexdigest(),
                    sources_sha256=hashlib.sha256((build/'sources.json').read_bytes()).hexdigest(),
                    build_result=status, mapped_lut_gate=mapped, device_lut_capacity=66600, strict_limit=46620,
                    total_lut=total, utilization_percent=100*total/66600,
                    below_70_percent=total < 46620, needed_reduction_for_strict_limit=max(0, total-46619),
                    attribution='ADS SYN hierarchy, not post-route or measured deletion savings', modules=rows)
    (build/'module_resources.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
    with (build/'module_resources.csv').open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    # Show a disjoint frontier: expand core exactly once and retain each other
    # root child whole. Root/core local glue are explicit residuals, not lost.
    frontier = []
    root = rows[0]['path']
    core = root + '/core'
    for row in rows:
        if row['depth'] == 1 and row['path'] != core or row['depth'] == 2 and row['path'].startswith(core+'/'):
            frontier.append((row['path'].removeprefix(root+'/'), row['lut'], row['ff'], row['apm'], row['drm']))
        elif row['path'] in (root, core) and row['own_lut']:
            frontier.append((row['path'].removeprefix(root+'/')+'（本层逻辑）', row['own_lut'], None, None, None))
    assert sum(row[1] for row in frontier) == total
    lines = ['# 整板 LUT 模块占用', '', f'构建：`{build.name}`。原始报告：`synthesize/pango_video_system.snr`。',
             '', f'总 LUT：**{total:,} / 66,600（{100*total/66600:.2f}%）**。严格低于 70% 要求不超过 46,619；仍需减少 {max(0,total-46619):,}。',
             '', '以下为同一整板 SYN 层级归属，互不重复，可加总。FF/APM/DRM 的破折号表示本层残差未拆分。',
             '模块删除会改变常量传播、共享与接口逻辑；表中占用不能直接承诺为删除收益。MAP/STA 状态以 result.json 为准。',
             '', '| 模块实例 | LUT | 占器件 | FF | APM | DRM |', '| --- | ---: | ---: | ---: | ---: | ---: |']
    for path, lut, ff, apm, drm in sorted(frontier, key=lambda x: -x[1]):
        vals = [str(v) if v is not None else '—' for v in (ff, apm, drm)]
        lines.append(f'| `{path}` | {lut:,} | {100*lut/66600:.2f}% | {" | ".join(vals)} |')
    lines += ['', ('MAP 硬门禁：LUT='+str(mapped['total_lut'])+'，严格低于70%：'+str(mapped['below_70_percent']))
              if mapped['valid'] else 'MAP 硬门禁：证据缺失或不合法，禁止布线。'+mapped['error']]
    lines += ['', '完整所有层级在 module_resources.csv / .json；父模块行包含其子模块，不可再次累计。',
              '', f'原生阶段：{status.get("stage")}；错误数量：{len(status.get("errors",[]))}；未由本表执行时序或实板验证。']
    (build/'module_resources.md').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    print(json.dumps({k: evidence[k] for k in ('total_lut','utilization_percent','below_70_percent','needed_reduction_for_strict_limit')}))


if __name__ == '__main__':
    main()
