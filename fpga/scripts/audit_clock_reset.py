"""Audit PDS source snapshots, min/max timing and mapped CDC connections.

Reads hierarchical synthesis Verilog and routed instance inventory. This is
structural/STA evidence only, not an MTBF, PHY-delay or frame-lifecycle proof.
"""
import argparse
import fnmatch
import hashlib
import json
from pathlib import Path
import re


def read(path):
    """Accept native UTF-8/BOM reports without silently dropping content."""
    return path.read_text(encoding='utf-8-sig', errors='replace')


def flatten(text, top):
    """Elaborate named-port native synthesis modules into scalar cell nets.

    Only simple scalar nets are required for pointer/reset checks. Unsupported
    expressions remain explicit strings and cannot falsely pass a net match.
    """
    modules = dict(re.findall(r'\bmodule\s+(\w+)\b(.*?)\bendmodule', text, re.S))
    cells = {}
    expression = re.compile(r'^\s*(?:\(\*[^\n]*\*\)\s*)?(\w+)\s+'
                            r'(?:/\*\s*(.*?)\*/\s*)?(?:#\((.*?)\)\s*)?'
                            r'(\\[^\s]+|\w+)\s*\((.*?)\);', re.M | re.S)

    def clean(value):
        return re.sub(r'\s+', '', value.strip().lstrip('\\'))

    def elaborate(module, prefix, ports):
        def net(value):
            value = clean(value)
            if not value or "'" in value or '{' in value:
                return value
            return ports.get(value, prefix+value)
        for match in expression.finditer(modules[module]):
            kind, original, params, instance, connections = match.groups()
            name = clean(original or instance)
            pins = {clean(pin): net(value) for pin, value in
                    re.findall(r'\.(\\[^\s]+|\w+)\s*\((.*?)\)', connections, re.S)}
            if kind in modules:
                elaborate(kind, prefix+name+'.', pins)
            elif kind.startswith('GTP_'):
                cells[prefix+name] = dict(kind=kind, pins=pins)
    elaborate(top, '', {})
    return cells


def main():
    """Require live endpoints and retained timed synchronization stages."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    args = parser.parse_args()
    run = args.run.resolve()
    result = json.loads(read(run / 'result.json'))
    top = 'Top' if result['project']=='mini_camera_diag' else 'pango_video_top'
    for relative, digest in json.loads(read(run / 'source_hashes.json')).items():
        assert hashlib.sha256((run / 'source' / relative).read_bytes()).hexdigest()==digest, relative
    text = read(run / f'report_timing/{top}.rtr')
    timing = {}
    for mode in ('Setup', 'Hold', 'Recovery', 'Removal'):
        for corner in ('Slow', 'Fast'):
            part = re.search(rf'{mode} Summary\({corner} Corner\):(.*?)(?=\n=+)', text, re.S)
            assert part is not None, (mode, corner)
            rows = re.findall(r'^\s*(\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$', part[1], re.M)
            assert rows, (mode, corner, 'no rows')
            timing[mode+'_'+corner] = dict(wns_ns=min(float(r[2]) for r in rows),
                tns_ns=sum(float(r[3]) for r in rows), failing_endpoints=sum(int(r[4]) for r in rows), rows=rows)
    wave = re.search(r'pixel_clk\s+([\d.]+)\s+\{([\d.]+)\s+([\d.]+)\}',text)
    assert wave and abs((float(wave[3])-float(wave[2]))/float(wave[1])-.4)<.001, 'pixel duty'
    cells = flatten(read(run / f'synthesize/{top}_syn.vm'), top)
    assert 'u_video_start.pixel_ready_meta' in cells, 'parser/first-stage missing'
    # Count routed instances independently from the synthesis parser; transformed
    # leaf names retain the original prefix plus an implementation suffix.
    routed = read(run / f'place_route/{top}_pnr.netlist')
    routed_names = re.findall(r'^Inst\n([^;\n]+);', routed, re.M)
    fdc = '\n'.join(read(p) for p in (run/'source/constraints').rglob('*.fdc'))
    gray = []
    for start, end in re.findall(r'set_max_delay 6\.0 -datapath_only -from \[get_cells \{([^}]+)\}\] -to \[get_cells \{([^}]+)\}\]', fdc):
        if not ('wptr*' in start or 'rptr*' in start):
            continue
        sources = {n:c for n,c in cells.items() if fnmatch.fnmatchcase(n,start)}
        targets = {n:c for n,c in cells.items() if fnmatch.fnmatchcase(n,end)}
        assert sources and targets, ('missing Gray endpoint',start,end)
        source_q = {c['pins'].get('Q') for c in sources.values()}
        connections = {n:c['pins'].get('D') in source_q for n,c in targets.items()}
        assert all(connections.values()), ('Gray connection mismatch', connections)
        # First-stage bounds must leave a real, connected second stage. Check
        # actual Q->D connectivity instead of assuming a register name proves it.
        matched_route = [n for n in routed_names if n.replace('/','.').startswith(end.rstrip('*'))]
        # Native width conversion can prune unused low pointer synchronizers
        # at Device Map. Require an explicit removal log for every absent bit,
        # instead of treating synthesis counts as routed endpoint counts.
        mapped_targets = {n for n in targets if any(r.replace('/','.').startswith(n+'.') for r in matched_route)}
        pruned = sorted(set(targets)-mapped_targets)
        console = read(run/'console.log')
        for name in pruned:
            native_name = name.rsplit('.ASYN_CTRL.',1)
            native_name = native_name[0].replace('.','/')+'/ASYN_CTRL.'+native_name[1]
            assert re.search(re.escape("Instance '"+native_name+"'")+r'.*dangling and will be cleaned', console), ('unexplained pruning',name)
        assert len(matched_route)+len(pruned)==len(targets), ('route endpoint count',end)
        second_stages = {}
        for name in mapped_targets:
            cell = targets[name]
            following = [n for n,c in cells.items() if c['kind'].startswith('GTP_DFF')
                         and c['pins'].get('D')==cell['pins'].get('Q')
                         and c['pins'].get('CLK')==cell['pins'].get('CLK')]
            assert following, ('Gray second stage missing/disconnected',name)
            second_stages[name] = following
        gray.append(dict(source_pattern=start,target_pattern=end,source_count=len(sources),
                         first_stage_count=len(targets),routed_first_stage_count=len(matched_route),
                         device_map_pruned=pruned,direct_connections=connections,second_stages=second_stages))
    assert gray, 'no gray constraints audited'
    # Preserve normal data timing from the meta register through both stages.
    meta = cells['u_video_start.pixel_ready_meta']
    stages = [cells[f'u_video_start.pixel_stages[{i}]'] for i in range(2)]
    assert stages[0]['pins']['D']==meta['pins']['Q'] and stages[1]['pins']['D']==stages[0]['pins']['Q']
    reference_q = cells['u_video_start.rs_ref.stages[2]']['pins']['Q']
    assertion_nets = {reference_q}
    for cell in cells.values():
        if cell['kind']=='GTP_INV' and cell['pins'].get('I')==reference_q:
            assertion_nets.add(cell['pins']['Z'])
    assert all(stage['pins'].get('C') in assertion_nets for stage in [meta]+stages), 'pixel asynchronous reset connection'
    assert all(stage['pins']['D'] not in assertion_nets for stage in [meta]+stages), 'reset exception also hides data'
    pulse_q = cells['u_video_start.divider_reset_n']['pins']['Q']
    reset_nets = {pulse_q}
    for c in cells.values():
        if c['kind']=='GTP_INV' and c['pins'].get('I')==pulse_q:
            reset_nets.add(c['pins']['Z'])
    loads = [(name,c['kind'],pin) for name,c in cells.items() for pin,n in c['pins'].items()
             if n in reset_nets and pin not in ('Q','Z')]
    startup_loads = [load for load in loads if load[1]!='GTP_INV']
    assert len(startup_loads)==9, ('startup reset fanout',startup_loads)
    assert all((kind=='GTP_IOCLKDIV_E2' and pin=='RST_N') or (kind=='GTP_OSERDES_E2' and pin=='RST')
               for _,kind,pin in startup_loads), startup_loads
    synthesis = read(run / f'synthesize/{top}.snr')
    resources = {name:int(re.search(expression,synthesis)[1]) for name,expression in {
        'lut':r'Total LUTs:\s+(\d+)', 'ff':r'Total Registers:\s+(\d+)',
        'oserdes_e2':r'GTP_OSERDES_E2\s+(\d+) use', 'ioclkbuf':r'GTP_IOCLKBUF\s+(\d+) use'}.items()}
    summary = dict(project=result['project'],timing=timing,pixel_period_ns=float(wave[1]),
        resources=resources,gray=gray,startup_reset_loads=startup_loads,
        pixel_sync_chain_connected=True,internal_timing_met=result['internal_timing_met'],
        external_timing_verified=False,hardware_tested=False)
    (run/'clock_reset_audit.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k not in ('timing','gray')}))
    print('GRAY_ENDPOINTS '+str([(g['source_count'],g['first_stage_count']) for g in gray]))


if __name__=='__main__':
    main()
