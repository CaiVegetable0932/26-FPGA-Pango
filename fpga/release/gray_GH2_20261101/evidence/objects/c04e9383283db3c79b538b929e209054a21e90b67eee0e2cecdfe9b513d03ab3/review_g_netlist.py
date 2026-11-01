"""Bounded, read-only G/DE CE netlist comparison; never launch native work.

Only review JSON/Markdown are written under G_integration and fpga/reports.
--baseline-only extracts the completed DE four-enable baseline while G runs.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/parameter_ce_20261031/G_integration'
BANK_FIELDS = {'shadow': ('shadow', 'shadow_id', 'shadow_version'),
               'active': ('active_entity', 'active_entity_id', 'active_version',
                          'applied_epoch', 'applied_frame')}
FIELD_NAMES = {name for fields in BANK_FIELDS.values() for name in fields}
EXPECTED_DE = {'geometries': {'shadow': 608, 'active': 736},
               'references': {'shadow': 351, 'active': 479}}


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    """Publish only complete review records for readers and external agents."""
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')
    temporary.replace(path)


def ranges(values):
    """Compact explicit bit coverage without hiding holes or duplicate FFs."""
    values = sorted(set(values)); spans = []
    for bit in values:
        if spans and bit == spans[-1][1] + 1:
            spans[-1][1] = bit
        else:
            spans.append([bit, bit])
    return ','.join(str(a) if a == b else f'{a}-{b}' for a, b in spans)


def verify_source(build, manifest):
    """A completed SYN must consume and retain the exact selected 327 files."""
    result = read(build / 'result.json')
    actual = read(build / 'sources.json')
    if result.get('native_exit') != 0 or result.get('errors') or not result.get('snapshot_intact'):
        raise ValueError('SYN result is not complete/passing: ' + str(build))
    if len(actual) != 327 or actual != manifest:
        raise ValueError('SYN manifest differs from candidate')
    if any(sha(build / 'source' / n) != h for n, h in manifest.items()):
        raise ValueError('SYN source bytes drifted')


def parse_cells(block):
    """Parse this PDS structural-VM form and fail if any primitive is missed.

    PDS comments retain original register names even when Q is exported under
    pose_status aliases. These names identify payload/metadata bits; CE uses
    actual connected net names, not an attribute or source-code estimate.
    """
    cells = []
    pattern = r'(?m)^\s*(GTP_\w+)\s+/\*\s*(.*?)\s*\*/(.*?);'
    for match in re.finditer(pattern, block, re.S):
        ports = {k: v.strip() for k, v in re.findall(r'\.(\w+)\s*\(([^()]*)\)', match[3])}
        name = match[2].strip().lstrip('\\')
        cells.append(dict(type=match[1], name=name, ports=ports))
    expected = len(re.findall(r'(?m)^\s*GTP_\w+\s', block))
    if not cells or len(cells) != expected:
        raise ValueError(f'Primitive parser incomplete: {len(cells)}/{expected}')
    return cells


def bank_summary(module_name, block):
    """Count all selected CE sinks, keeping each replicated driver branch."""
    cells = parse_cells(block)
    drivers = defaultdict(list); sinks = defaultdict(list)
    fields = defaultdict(list); all_ce = defaultdict(list)
    outputs = set(re.findall(r'(?m)^\s*output\s+(?:\[[^]]+\]\s+)?([^,\n]+)', block))
    for cell in cells:
        ports = cell['ports']
        for port, signal in ports.items():
            if port in ('Q', 'Z'):
                drivers[signal].append(cell)
            elif port in ('CE', 'CLK', 'C', 'P', 'D') or re.fullmatch(r'I\d+', port):
                sinks[signal].append(dict(cell=cell['name'], type=cell['type'], port=port))
        if cell['type'].startswith('GTP_DFF'):
            if 'CE' in ports:
                all_ce[ports['CE']].append(cell['name'])
            matched = re.fullmatch(r'(\w+)\[(\d+)\](?:_copy(?:_\d+)?)?', cell['name'])
            if matched and matched[1] in FIELD_NAMES:
                if 'CE' not in ports:
                    raise ValueError('Selected payload/metadata FF lacks CE: ' + cell['name'])
                fields[matched[1]].append(dict(bit=int(matched[2]), cell=cell['name'],
                    primitive=cell['type'], ce=ports['CE'], q=ports.get('Q'),
                    d=ports.get('D'), reset=ports.get('C', ports.get('P')), clk=ports.get('CLK')))
    groups = {}
    for group, names in BANK_FIELDS.items():
        chosen = [ff for name in names for ff in fields[name]]
        if any(not fields[name] for name in names):
            raise ValueError('Bank lost an entire payload/metadata field')
        branches = {}
        for net in sorted({ff['ce'] for ff in chosen}):
            target = [ff for ff in chosen if ff['ce'] == net]
            source = drivers[net]
            if len(source) != 1:
                raise ValueError('CE driver is not uniquely resolved within bank: ' + net)
            driver = source[0]
            branches[net] = dict(selected_ff_ce_count=len(target),
                all_local_ff_ce_count=len(all_ce[net]), local_input_pin_count=len(sinks[net]),
                non_ce_sinks=[item for item in sinks[net] if item['port'] != 'CE'],
                module_output=net in outputs,
                driver=dict(type=driver['type'], cell=driver['name'],
                    init=driver['ports'].get('INIT'),
                    inputs={p:s for p,s in driver['ports'].items() if re.fullmatch(r'I\d+', p)}),
                coverage={name:ranges(ff['bit'] for ff in fields[name] if ff['ce'] == net)
                          for name in names},
                ff_cells=[ff['cell'] for ff in target])
        groups[group] = dict(retained_ff_count=len(chosen), branch_count=len(branches),
            max_selected_ff_ce=max(len([ff for ff in chosen if ff['ce'] == net]) for net in branches),
            max_all_local_ff_ce=max(branch['all_local_ff_ce_count'] for branch in branches.values()),
            max_local_input_pins=max(branch['local_input_pin_count'] for branch in branches.values()),
            branches=branches)
    selected_cells = {ff['cell'] for row in fields.values() for ff in row}
    all_ce_cells = {name for row in all_ce.values() for name in row}
    if selected_cells != all_ce_cells:
        raise ValueError('CE-enabled FF not covered by payload/metadata groups: ' + str(all_ce_cells-selected_cells))
    # Replication moves load to the qualifying control inputs. Keep those
    # actual local loads visible so small CE branches do not hide a new trunk.
    qualifying_inputs={signal for group in groups.values() for branch in group['branches'].values()
                       for signal in branch['driver']['inputs'].values() if signal in sinks}
    input_loads={signal:len(sinks[signal]) for signal in sorted(qualifying_inputs)}
    return dict(module=module_name, direct_primitives=dict(Counter(cell['type'] for cell in cells)),
        qualifying_control_input_loads=input_loads,
        max_qualifying_control_input_load=max(input_loads.values(),default=0),
        groups=groups, fields={name:dict(retained_count=len(items),
            bit_indices=sorted({ff['bit'] for ff in items}), ranges=ranges(ff['bit'] for ff in items),
            duplicate_ff_bits={str(k):v for k,v in Counter(ff['bit'] for ff in items).items() if v>1},
            cells=items) for name,items in fields.items()},
        all_ce_ff_covered=True,
        note='Counts are actual local CE sinks. Removed/unconsumed RTL bits are not counted as physical FFs; compare retained bit sets with DE. Local input-pin total additionally includes control LUT/D sinks.')


def inspect_syn(syn, manifest):
    """Resolve geometry/reference module identity from actual core instances."""
    verify_source(syn, manifest)
    path = syn / 'synthesize/pango_video_system_syn.vm'; text = path.read_text(errors='strict')
    result = {}
    for instance in ('geometries', 'references'):
        matches = re.findall(r'(?m)^\s+(\w+)\s+' + instance + r'\s*\(', text)
        if len(matches) != 1:
            raise ValueError('Bank instance is ambiguous: ' + instance)
        name = matches[0]
        module = re.search(r'(?m)^module\s+' + re.escape(name) + r'\s.*?endmodule', text, re.S)
        if not module:
            raise ValueError('Missing bank entity: ' + name)
        result[instance] = bank_summary(name, module[0])
    return dict(synthesis=str(syn), vm_sha256=sha(path),
        snr_sha256=sha(syn / 'synthesize/pango_video_system.snr'),
        result_sha256=sha(syn / 'result.json'), sources_sha256=sha(syn / 'sources.json'), banks=result)


def compare(base, current):
    """Require exact retained-bit coverage and measure actual CE distribution."""
    results = {}; coverage_ok = True
    for name in ('geometries', 'references'):
        before = base['banks'][name]; after = current['banks'][name]
        fields = {}
        for field in sorted(FIELD_NAMES):
            old = before['fields'][field]; new = after['fields'][field]
            same = old['bit_indices'] == new['bit_indices']
            fields[field] = dict(DE_count=old['retained_count'], G_count=new['retained_count'],
                retained_bit_sets_equal=same, missing=sorted(set(old['bit_indices'])-set(new['bit_indices'])),
                added=sorted(set(new['bit_indices'])-set(old['bit_indices'])))
            coverage_ok &= same
        groups = {}
        for group in BANK_FIELDS:
            old = before['groups'][group]; new = after['groups'][group]
            branches = new['branches']; count = new['branch_count']
            ce_bounded = new['max_all_local_ff_ce'] <= 32
            bounded = ce_bounded and new['max_local_input_pins'] <= 32
            replicated = count > old['branch_count']
            exported = any(branch['module_output'] for branch in branches.values())
            groups[group] = dict(DE_branches=old['branch_count'], G_branches=count,
                DE_max_ce=old['max_all_local_ff_ce'], G_max_ce=new['max_all_local_ff_ce'],
                DE_max_local_pins=old['max_local_input_pins'], G_max_local_pins=new['max_local_input_pins'],
                replicated=replicated, ce_fanout_32_met=ce_bounded, local_fanout_32_met=bounded,
                selected_ce_exported_from_module=exported,
                # CE32 is the design objective. Extra local logic inputs are
                # reported separately; two such consumers must not erase the
                # observed reduction from hundreds of CE loads to 32 per branch.
                intended_replication_visible=replicated and ce_bounded and not exported)
        results[name] = dict(fields=fields, groups=groups)
    effective = all(group['intended_replication_visible'] for bank in results.values() for group in bank['groups'].values())
    return dict(retained_payload_metadata_coverage_equal=coverage_ok,
        four_enables_replication_visible=effective, details=results,
        strict_total_input_fanout_32_all_met=all(group['local_fanout_32_met'] for bank in results.values() for group in bank['groups'].values()),
        acceptance='SYN structural intent visible; physical effect still unverified' if coverage_ok and effective else
                   'Do not promote on CE32 intent: actual branch/coverage criteria failed')


def main():
    """Read once, never wait for or launch a stage; incomplete evidence stays pending."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-only', action='store_true')
    args = parser.parse_args()
    de_root = FPGA / 'build/DE_optimization_20261031'
    de_state = read(de_root / 'native/state.json'); dm = read(de_root / 'candidate/sources.json')
    base = inspect_syn(Path(de_state['synthesis']), dm)
    for bank, groups in EXPECTED_DE.items():
        for name, expected in groups.items():
            actual = base['banks'][bank]['groups'][name]
            if actual['retained_ff_count'] != expected or actual['branch_count'] != 1:
                raise ValueError('DE baseline no longer matches reviewed four-enable counts')
    save(ROOT / 'DE_ce_baseline.json', base)
    if args.baseline_only:
        print('DE_CE_BASELINE_VERIFIED ' + str(ROOT / 'DE_ce_baseline.json')); return
    state = read(ROOT / 'native/state.json'); syn = Path(state['synthesis'])
    if not (syn / 'result.json').exists():
        print('G_SYN_PENDING; DE baseline parsed, no G result asserted'); return
    manifest = read(ROOT / 'candidate/sources.json')
    if sha(ROOT / 'candidate/sources.json') != state['sources_sha256']:
        raise ValueError('G native manifest identity mismatch')
    current = inspect_syn(syn, manifest); comparison = compare(base, current)
    from finalize_gray_verification import timing_summary
    from review_gray_candidates import inspect
    timing = timing_summary(syn); old_timing = timing_summary(Path(de_state['synthesis']))
    if set(timing['estimated_setup_ns']) != set(old_timing['estimated_setup_ns']):
        raise ValueError('Clock set changed relative to DE')
    result = dict(checked_at=datetime.now().astimezone().isoformat(),
        status='G_SYN_NETLIST_REVIEW_MAP_PENDING', baseline=base, current=current,
        comparison=comparison, timing=timing, DE_timing=old_timing,
        estimated_setup_delta_vs_DE={k:v-old_timing['estimated_setup_ns'][k] for k,v in timing['estimated_setup_ns'].items()},
        native_state_at_read=state['status'], physical_routing_verified=False,
        live_rtl_modified=False, automatically_promoted=False)
    if state['status'] == 'SYN_MAP_COMPLETE_NETLIST_REVIEW_REQUIRED':
        actual = inspect(syn, Path(state['mapping']))
        old = inspect(Path(de_state['synthesis']), Path(de_state['mapping']))
        result.update(status='G_SYN_MAP_NETLIST_REVIEW_COMPLETE',
            mapping_resources=actual['mapping_resources'], DE_mapping_resources=old['mapping_resources'],
            delta_vs_DE={k:v-old['mapping_resources'][k] for k,v in actual['mapping_resources'].items()},
            constraints=actual['constraints'], native_review_sha256=sha(ROOT / 'native_review.json'))
    save(ROOT / 'netlist_review.json', result)
    rows=[]
    for bank, details in comparison['details'].items():
        for name, item in details['groups'].items():
            rows.append(f'| {bank}/{name} | {item["DE_branches"]} | {item["G_branches"]} | {item["DE_max_ce"]} | {item["G_max_ce"]} | {item["G_max_local_pins"]} | {item["intended_replication_visible"]} |')
    content=['# G 参数 CE32 实际综合网表审查','',
        '本报告来自真实已结束 SYN，未进行新布局布线。综合时序估计不等于布线后 STA。','',
        f'状态：`{result["status"]}`。全 payload/metadata 保留位集合一致：`{comparison["retained_payload_metadata_coverage_equal"]}`。',
        f'四组使能均观察到有效局部复制：`{comparison["four_enables_replication_visible"]}`。','',
        f'所有分支的总输入脚负载均≤32：`{comparison["strict_total_input_fanout_32_all_met"]}`。CE负载与额外本地逻辑消费端分开报告；总负载略超过32不等于未发生复制，也不是用户设置的否决门限。','',
        '| 使能组 | DE分支 | G分支 | DE最大CE负载 | G最大CE负载 | G最大本地总输入脚负载 | CE复制且≤32 |',
        '|---|---:|---:|---:|---:|---:|---|',*rows,'',
        '每分支驱动单元、INIT/输入、CE负载、非CE消费端、逐字段位范围及完整FF清单保存在JSON。reference的RTL宽度包含已被DE综合裁剪的未消费位；本次对比全部实际保留位，未将已裁剪位误报为丢失。','',
        f'结论：{comparison["acceptance"]}。若CE仍集中到单根网，属性没有达到目标；仅凭最终网表不能断言是未复制还是中途复制后被合并。','',
        f'网表证据：`{(ROOT/"netlist_review.json").as_posix()}`','',
        '## 资源与时序','',
        '```json',json.dumps({k:result.get(k) for k in ('mapping_resources','DE_mapping_resources','delta_vs_DE','estimated_setup_delta_vs_DE')},indent=2),'```','',
        '时序完整时钟估计及已报告hold/removal路径保留在JSON；DDR真实hold仍需实际PnR。未修改live、候选、包、readiness，未自动提升G。','']
    report=FPGA/'reports/G参数CE32实际网表审查_20261031.md'
    report.write_text('\n'.join(content),encoding='utf-8')
    print(result['status'],comparison['acceptance'],str(report))


if __name__ == '__main__':
    main()
