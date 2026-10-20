"""Append one dated observation row for the DeepSeek routing round to observations.jsonl.

按交接文件第 7 节，每次观察持久化为一行 JSONL：时间、driver/native PID、
阶段、elapsed、轮次与最少未布通数、最近窗口改善、CPU 时间、日志大小与
静默时间、进程 CPU/内存、预算与下次动作。原生 monitor 中已有的字段直接
引用；缺失指标写入字符串"不可获得"，不补造数值。
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def latest_evidence(build):
    """本轮 resume_* 目录按名称排序取最新；空则返回 None（尚不可获得）。"""
    dirs = sorted(build.glob('resume_*'))
    return dirs[-1] if dirs else None


def last_row(path):
    """读取 monitor JSONL 最后一行；缺失或损坏时显式标为不可获得。"""
    if not path.is_file():
        return None, '不可获得'
    try:
        lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
        if not lines:
            return None, '不可获得'
        return json.loads(lines[-1]), None
    except json.JSONDecodeError:
        return None, '不可获得'


def phase_fields(evidence, phase):
    """提取单个原生阶段的最新监控行及日志字节数。"""
    row, missing = last_row(evidence / (phase + '_monitor.jsonl'))
    log = evidence / (phase + '.log')
    out = {'phase': phase}
    if row is None:
        out.update(status='不可获得', elapsed_seconds='不可获得', pid='不可获得',
                   rounds='不可获得', best_unrouted='不可获得', log_bytes='不可获得',
                   log_idle_seconds='不可获得', warning='不可获得',
                   cpu_seconds='不可获得', rss_bytes='不可获得')
        out['missing'] = missing
        return out
    rounds = row.get('rounds') or []
    resources = row.get('resources') or {}
    out.update(status=row.get('status'), elapsed_seconds=row.get('elapsed_seconds'),
               pid=row.get('pid'), rounds=len(rounds),
               best_unrouted=row.get('best_unrouted'),
               log_bytes=log.stat().st_size if log.is_file() else '不可获得',
               log_idle_seconds=row.get('log_idle_seconds'),
               warning=row.get('warning'), timeout_seconds=row.get('timeout_seconds'),
               cpu_seconds=resources.get('sampled_cpu_seconds', '不可获得'),
               rss_bytes=resources.get('sampled_rss_bytes', '不可获得'))
    # 最近窗口改善：监督器规则取最近 5 轮窗口最优与窗口起点对比；
    # 原生行已含全部轮次，这里只转述最近窗口起止，供趋势判断。
    if len(rounds) >= 2:
        recent = rounds[-6:] if len(rounds) >= 6 else rounds
        out['recent_window_unrouted_first_last'] = (recent[0]['unrouted'], recent[-1]['unrouted'])
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--next-action', default='继续定时观察', help='本次观察后的下一步动作')
    args = parser.parse_args()
    evidence = latest_evidence(args.build)
    row = {'at': datetime.now(timezone.utc).isoformat(),
           'evidence': str(evidence) if evidence else None}
    if evidence is None:
        row['note'] = 'resume_* 证据目录尚未出现'
    else:
        row['phases'] = [phase_fields(evidence, phase)
                         for phase in ('place_route', 'report_timing')]
        # driver 身份与启动信息来自本轮会话 launch.json，不做重复推断
        launch = args.session / 'launch.json'
        if launch.is_file():
            row['launch'] = json.loads(launch.read_text(encoding='utf-8'))
        else:
            row['launch'] = '不可获得'
    row['next_action'] = args.next_action
    path = args.session / 'observations.jsonl'
    with path.open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(row, ensure_ascii=False) + '\n')
    print(json.dumps(row, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
