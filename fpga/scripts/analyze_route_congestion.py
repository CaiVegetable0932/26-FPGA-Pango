"""Read-only congestion analysis for a completed/terminated native P&R round.

用途：解析 PDS 布线导出的 CongestionNetInfo_N.txt 与 CongestionPlot_N.txt，
在不启动 PDS、不修改冻结工程的前提下，量化：
  1. 每轮拥塞最大值与超阈值网线数（收敛趋势）；
  2. 终结迭代中按设计层级聚合的拥塞贡献（定位热点模块）；
  3. 按器件坐标区域聚合的拥塞热点（定位热点 tile 区域）；
  4. 持续拥塞网线（iter 0 与终结迭代均上榜）与已解决网线；
  5. 网格拥塞图（CongestionPlot）中最热的格子。
输出：JSON + Markdown 报告，写入指定 fpga/reports 路径；脚本只读取证据目录。
"""
import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

LINE = re.compile(r'congestion value : (\d+), drive info : (\S+), design net name : (.+)$')
SITE = re.compile(r'([A-Za-z]+)_(\d+)_(\d+)')


def parse_netinfo(path):
    """解析单个 CongestionNetInfo 文件；返回 (value, site, coordinate, net) 列表。"""
    rows = []
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        m = LINE.search(line)
        if not m:
            continue
        value, site, net = int(m.group(1)), m.group(2), m.group(3).strip()
        s = SITE.match(site.split(':')[0])
        coord = (int(s.group(2)), int(s.group(3))) if s else None
        rows.append((value, site, coord, net))
    return rows


def hierarchy(net, depth=3):
    """按层级前缀聚合网线名；取前 depth 段，用于定位热点模块。"""
    parts = net.split('/')
    return '/'.join(parts[:depth]) if len(parts) > depth else net


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--netinfo-dir', type=Path, required=True)
    parser.add_argument('--plot-dir', type=Path, required=True)
    parser.add_argument('--json-out', type=Path, required=True)
    parser.add_argument('--md-out', type=Path, required=True)
    parser.add_argument('--region', type=int, default=60,
                        help='坐标聚合桶大小（器件坐标单位），默认 60')
    args = parser.parse_args()

    files = sorted(args.netinfo_dir.glob('CongestionNetInfo_*.txt'),
                   key=lambda p: int(p.stem.rsplit('_', 1)[1]))
    if not files:
        raise SystemExit('no CongestionNetInfo files found')
    iterations = [int(p.stem.rsplit('_', 1)[1]) for p in files]
    last = files[-1]

    def load(path):
        return parse_netinfo(path)

    # 1) 每轮摘要：最大值、超阈值计数、条目数
    trend = []
    for path in files:
        rows = load(path)
        values = [r[0] for r in rows]
        trend.append({
            'iteration': int(path.stem.rsplit('_', 1)[1]),
            'entries': len(rows),
            'max': max(values) if values else 0,
            'ge30': sum(1 for v in values if v >= 30),
            'ge50': sum(1 for v in values if v >= 50),
            'sum': sum(values),
        })

    # 2) 终结迭代按层级聚合
    final_rows = load(last)
    final_iter = int(last.stem.rsplit('_', 1)[1])
    by_hier = defaultdict(lambda: {'count': 0, 'sum': 0, 'max': 0})
    for value, site, coord, net in final_rows:
        key = hierarchy(net)
        item = by_hier[key]
        item['count'] += 1
        item['sum'] += value
        item['max'] = max(item['max'], value)
    top_hier = sorted(by_hier.items(), key=lambda kv: kv[1]['sum'], reverse=True)[:25]

    # 3) 终结迭代按坐标区域聚合（x/y 各按 region 分桶）
    by_region = defaultdict(lambda: {'count': 0, 'sum': 0, 'max': 0})
    for value, site, coord, net in final_rows:
        if coord is None:
            continue
        key = (coord[0] // args.region * args.region, coord[1] // args.region * args.region)
        item = by_region[key]
        item['count'] += 1
        item['sum'] += value
        item['max'] = max(item['max'], value)
    top_regions = sorted(by_region.items(), key=lambda kv: kv[1]['sum'], reverse=True)[:20]

    # 4) 持续拥塞 vs 已解决：对比 iter 0 与终结迭代的上榜网线
    first_rows = load(files[0])
    first_map = {net: value for value, site, coord, net in first_rows}
    final_map = {net: value for value, site, coord, net in final_rows}
    top_final = sorted(final_rows, key=lambda r: r[0], reverse=True)[:100]
    chronic = [{'net': net, 'final': value, 'first': first_map.get(net)}
               for value, site, coord, net in top_final if net in first_map]
    new_hot = [{'net': net, 'final': value}
               for value, site, coord, net in top_final if net not in first_map]
    resolved = sorted(({'net': net, 'first': value, 'final': final_map.get(net)}
                       for net, value in first_map.items() if net not in final_map),
                      key=lambda r: r['first'], reverse=True)[:50]

    # 5) 网格拥塞图：热格统计
    plot_file = args.plot_dir / f'CongestionPlot_{final_iter}.txt'
    plot = {'file': str(plot_file), 'header': [], 'hot_cells': [], 'sum': 0, 'max': 0}
    if plot_file.is_file():
        grid = []
        for line in plot_file.read_text(encoding='utf-8', errors='replace').splitlines():
            if ':' in line:
                plot['header'].append(line.strip())
                continue
            try:
                grid.append([int(v) for v in line.split()])
            except ValueError:
                continue
        hot = []
        for y, row in enumerate(grid):
            for x, v in enumerate(row):
                if v > 0:
                    hot.append((v, x, y))
                    plot['sum'] += v
                    plot['max'] = max(plot['max'], v)
        hot.sort(reverse=True)
        plot['hot_cells'] = [{'value': v, 'x': x, 'y': y} for v, x, y in hot[:30]]
        plot['rows'] = len(grid)

    result = {
        'iterations': iterations,
        'final_iteration': final_iter,
        'trend': trend,
        'final_top_hierarchy': [{'prefix': k, **v} for k, v in top_hier],
        'final_top_regions': [{'x0': k[0], 'y0': k[1], **v} for k, v in top_regions],
        'chronic_top_nets': chronic,
        'new_hot_top_nets': new_hot,
        'resolved_top_nets': resolved,
        'congestion_plot_final': plot,
    }
    args.json_out.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')

    # Markdown 摘要（便于人工评审与提交）
    lines = ['# 布线拥塞分析（只读）', '',
             f'终结迭代：{final_iter}；分析文件数：{len(files)}；区域桶：{args.region}', '',
             '## 每轮趋势（节选）', '',
             '| iter | entries | max | >=30 | >=50 | sum |', '| --- | --- | --- | --- | --- | --- |']
    for row in trend[::max(1, len(trend) // 15)]:
        lines.append(f"| {row['iteration']} | {row['entries']} | {row['max']} | "
                     f"{row['ge30']} | {row['ge50']} | {row['sum']} |")
    lines += ['', f'## 终结迭代按层级（前 25）', '',
              '| prefix | count | sum | max |', '| --- | --- | --- | --- |']
    for item in result['final_top_hierarchy']:
        lines.append(f"| `{item['prefix']}` | {item['count']} | {item['sum']} | {item['max']} |")
    lines += ['', f'## 终结迭代按坐标区域（前 20，桶 {args.region}）', '',
              '| x0 | y0 | count | sum | max |', '| --- | --- | --- | --- | --- |']
    for item in result['final_top_regions']:
        lines.append(f"| {item['x0']} | {item['y0']} | {item['count']} | {item['sum']} | {item['max']} |")
    lines += ['', '## 终结迭代最热网线（前 20）', '',
              '| value | net | iter0 value |', '| --- | --- | --- |']
    for value, site, coord, net in final_rows[:20]:
        lines.append(f"| {value} | `{net}` | {first_map.get(net, '—')} |")
    lines += ['', '## 网格拥塞图热点格（前 20）', '',
              '| value | x | y |', '| --- | --- | --- |']
    for cell in plot['hot_cells'][:20]:
        lines.append(f"| {cell['value']} | {cell['x']} | {cell['y']} |")
    args.md_out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('wrote', args.json_out)
    print('wrote', args.md_out)
    print('final iteration', final_iter, 'max', trend[-1]['max'], 'entries', trend[-1]['entries'])


if __name__ == '__main__':
    main()
