"""Conservative mapped processing clock/CDC audit; never claims routed timing."""
from pathlib import Path
import argparse,fnmatch,hashlib,json,re
from audit_clock_reset import flatten
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--mapping',type=Path,required=True)
    a=p.parse_args();r=a.mapping.resolve()
    record=r/'mapping_validation.json' if (r/'mapping_validation.json').exists() else r/'result.json'
    result=json.loads(record.read_text())
    assert result['passed'] and result['inputs_intact']
    b=Path(result['source_build']);hashes=result['source_hashes']
    assert all(sha(b/'source'/n)==v for n,v in hashes.items())
    vm=r/'synthesize/pango_video_system_syn.vm';cells=flatten(vm.read_text(),'pango_video_system')
    checks=[];errors=[]
    def require(ok,label):
        checks.append(dict(check=label,passed=bool(ok)))
        if not ok:errors.append(label)
    # Exact primitive connections prove a real global processing clock; the
    # configured 6/5 ratio is independently checked in its frozen IP source.
    pll=cells.get('u_processing_pll.u_gpll');buf=cells.get('u_processing_global')
    require(pll is not None and buf is not None,'processing PLL and global buffer retained')
    clock=buf['pins'].get('CLKOUT') if buf else None
    require(bool(clock) and pll and buf['pins'].get('CLKIN')==pll['pins'].get('CLKOUT1'),'PLL OUT1 drives processing global network')
    ip=(b/'source/ip/sys_pll/sys_pll.v').read_text()
    for key,value in [('CLKIN_FREQ',125),('STATIC_RATIOI',1),('STATIC_RATIOM',1),('STATIC_RATIOF',6),('STATIC_RATIO1',5)]:
        m=re.search(r'\b'+key+r'\s*=\s*([\d.]+)\s*;',ip)
        require(m is not None and float(m[1])==value,'processing PLL parameter '+key)
    cdc=(b/'source/constraints/video_system/processing_cdc.fdc').read_text()
    require('set_clock_groups' not in cdc and '-hold' in cdc,'no broad clock-group exception')
    bindings=[]
    def select(pattern):
        return {n:c for n,c in cells.items() if any(fnmatch.fnmatchcase(n,q) for q in pattern.split())}
    for line in cdc.splitlines():
        if not line.startswith('set_max_delay'):continue
        patterns=re.findall(r'get_cells -hierarchical \{([^}]+)\}',line)
        source=select(patterns[0]);target=select(patterns[1]) if len(patterns)>1 else {}
        to_clock='get_clocks processing_clk' in line
        require(bool(source) and (bool(target) or to_clock),'nonempty CDC endpoints: '+patterns[0])
        bindings.append(dict(source_pattern=patterns[0],target_pattern=patterns[1] if target else 'CLOCK:processing_clk',
            source_count=len(source),target_count=len(target),target_clock=to_clock))
        if to_clock:
            # The sole clock-target exception may only start in DDR registers.
            # It cannot accidentally relax processing-to-processing paths.
            require(all(c['kind'].startswith('GTP_DFF') and c['pins'].get('CLK')!=clock for c in source.values()),
                'held job sources all outside processing domain')
    pairs=[('core.processor.job_mailbox',q) for q in ['request','response','free']]
    pairs += [('core.processor.result_bridge',q) for q in ['request','response','free','cancel']]
    pairs += [('core.processor.refill_bridge','request'),('core','tone_ready')]
    chains=[]
    for prefix,stem in pairs:
        first=prefix+'.'+stem+'_meta';second=prefix+'.'+stem+('_ddr' if stem=='tone_ready' else '_sync')
        x=cells.get(first);y=cells.get(second)
        connected=bool(x and y and x['pins'].get('Q')==y['pins'].get('D') and x['pins'].get('CLK')==y['pins'].get('CLK'))
        require(connected,'retained connected synchronization stages: '+first)
        require(not any(fnmatch.fnmatchcase(second,q) for d in bindings for q in d['target_pattern'].split()),'second stage unexcepted: '+second)
        chains.append(dict(first=first,second=second,connected=connected,clock=x['pins'].get('CLK') if x else None))
    gray=[]
    for stem in ['write','read']:
        prefix='core.processor.refill_bridge.quads.';sources=select(prefix+stem+'_gray*');first=select(prefix+stem+'_meta*')
        require(bool(sources) and bool(first),'quad FIFO '+stem+' Gray cells retained')
        for name,c in first.items():
            second=name.replace('_meta[','_sync[');y=cells.get(second)
            direct=c['pins'].get('D') in {v['pins'].get('Q') for v in sources.values()}
            following=bool(y and y['pins'].get('D')==c['pins'].get('Q') and y['pins'].get('CLK')==c['pins'].get('CLK'))
            require(direct and following,'quad Gray source/meta/sync connected: '+name)
            gray.append(dict(first=name,second=second,direct_source=direct,second_connected=following))
    snr=r/'synthesize/pango_video_system.snr';text=snr.read_text()
    resources={k:float(re.search(pattern,text)[1]) for k,pattern in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),('APM',r'Total APMs = ([\d.]+)'),('DRM36_equivalent',r'Total DRM = ([\d.]+)')]}
    budgets=dict(LUT=50000,FF=95000,APM=180,DRM36_equivalent=120)
    require(all(resources[k]<=v for k,v in budgets.items()),'selected board synthesis within starting budgets')
    # Native MAP is the authoritative whole-board resource measurement. Also
    # compare the inherited board/PHY critical warnings without changing any
    # electrical settings simply to suppress their diagnostic messages.
    dmr=r/'device_map/pango_video_system.dmr';mapped_text=dmr.read_text()
    mapped_resources={k:float(re.search(r'\| '+label+r'\s+\|\s+([\d.]+)',mapped_text)[1])
        for k,label in [('LUT','LUT'),('FF','FF'),('APM','APM'),('DRM36_equivalent','DRM')]}
    require(all(mapped_resources[k]<=v for k,v in budgets.items()),'selected board MAP within starting budgets')
    f=Path(__file__).resolve().parents[1]
    baseline=f/'build/full_integration_20261013/delay_20261019_163458_368603/constraint_check/constraint_check.ccr'
    current=r/'constraint_check/constraint_check.ccr'
    def criticals(path):
        return sorted(re.sub(r'\[[^\n]*?\(line number: \d+\)\]\s*','',line.strip())
                      for line in path.read_text().splitlines() if line.strip().startswith('C:'))
    previous=criticals(baseline);present=criticals(current)
    require(previous==present and len(present)==61,'61 inherited board/PHY critical warnings unchanged')
    out=dict(passed=not errors,checks=checks,errors=errors,bindings=bindings,synchronizers=chains,gray=gray,
        resources=resources,mapped_resources=mapped_resources,starting_budgets=budgets,netlist_sha256=sha(vm),report_sha256=sha(snr),source_build=str(b),
        map_report_sha256=sha(dmr),constraint_check_sha256=sha(current),legacy_critical_warning_count=len(present),
        new_critical_warnings=sorted(set(present)-set(previous)),
        processing_clock_target_mhz=150,processing_clock_net=clock,structural_audit_only=True,
        routed_timing_signed_off=False,bundled_data_full_electrical_graph_checked=False,
        limitation='Cell binding and scalar synchronization checks do not establish routed max/hold delay, MTBF or every wide-bus/dual-clock RAM arc.')
    (r/'processing_mapping_audit.json').write_text(json.dumps(out,indent=2));print(json.dumps(out))
    if errors:raise SystemExit(1)
if __name__=='__main__':main()
