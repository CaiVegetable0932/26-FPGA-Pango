"""Collect only executed algorithm-06 model/RTL/PDS evidence, with source hashes.

JSON keeps software/RTL, post-PnR and board verification separate. Missing reports
are unavailable, never successful. Raw logs remain the authoritative detailed data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
FPGA=Path(__file__).resolve().parents[1]


def pds_result(path):
    """Read fresh native min/max corner rows and placed physical resource usage."""
    reports=list((path/'report_timing').glob('*.rtr'))
    result={'run':str(path),'available':False,'internal_sta_passed':False,'board_io_verified':False}
    if not reports:return result
    report=reports[0];text=report.read_text(encoding='utf-8',errors='replace')
    rows=re.findall(r'^\s*proc_clk\s+proc_clk\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$',text,re.M)
    checks=[dict(corner=corner,analysis=analysis,worst_ns=float(r[0]),total_ns=float(r[1]),failing=int(r[2]),endpoints=int(r[3]))
            for (corner,analysis),r in zip([('slow','setup'),('slow','hold'),('fast','setup'),('fast','hold')],rows)]
    result.update(available=True,report=str(report),corner_checks=checks,
                  internal_sta_passed=len(checks)==4 and all(r['worst_ns']>=0 and r['failing']==0 and r['endpoints']>0 for r in checks))
    log=(path/'place_route/run.log').read_text(encoding='utf-8',errors='replace')
    resources={}
    for label,key in [('Use of APM','apm'),('Use of DRM','physical_drm')]:
        match=re.search(r'\| '+label+r'\s*\|\s*(\d+)',log)
        if match:resources[key]=int(match[1])
    for label,key in [('FF','ff'),('LUT','lut')]:
        resources[key]=sum(int(x) for x in re.findall(r'\|\s{3}'+label+r'\s*\|\s*(\d+)',log))
    result['resources_with_harness']=resources
    manifest=path/'source_manifest.json'
    if manifest.exists():result['source_manifest']=json.loads(manifest.read_text(encoding='utf-8-sig'))
    return result


def main():
    """Persist a reviewable record without merging evidence from different source runs."""
    p=argparse.ArgumentParser();p.add_argument('--rtl-run',required=True);p.add_argument('--pds-run',required=True)
    p.add_argument('--output',default=str(FPGA/'reports/isp_geometry_20261012.json'));args=p.parse_args()
    rtl=Path(args.rtl_run).resolve();pds=Path(args.pds_run).resolve();output=Path(args.output).resolve()
    if not output.is_relative_to(FPGA/'reports'):raise ValueError('report must remain within fpga/reports')
    result_file=rtl/'result.json'
    rtl_result=json.loads(result_file.read_text(encoding='utf-8-sig')) if result_file.exists() else {'passed':False,'status':'unfinished'}
    model_file=rtl/'vectors/model_audit.json'
    model=json.loads(model_file.read_text()) if model_file.exists() else {'passed':False,'status':'unavailable'}
    benchmarks={}
    for log in rtl.glob('tb_*.log'):
        lines=[line for line in log.read_text(encoding='utf-8',errors='replace').splitlines() if '_PASS' in line or '_METRICS' in line]
        benchmarks[log.stem]=lines
    base=FPGA/'build/isp_geometry'
    names=['pds_lens_registered','pds_lens_partial_products','pds_bilinear_initial','pds_isp_initial','pds_isp_registered_ram',
           'pds_geometry_banked','pds_geometry_tag_pipeline','pds_geometry_immutable_identity','pds_geometry_local_tags','pds_geometry_seed1','pds_geometry_seed7']
    source={path.relative_to(FPGA).as_posix():hashlib.sha256(path.read_bytes()).hexdigest()
            for root in ('rtl/isp','rtl/geometry') for path in sorted((FPGA/root).glob('*.sv'))}
    # An extra overflow campaign shares the final RTL; do not claim it was part
    # of an older full-frame log. Preserve its own run identity and outcomes.
    overflow=base/'overflow_signoff/result.json'
    extra=json.loads(overflow.read_text(encoding='utf-8-sig')) if overflow.exists() else {'passed':False,'status':'unavailable'}
    result={'date':'2026-10-12','scope':'algorithm 06 offline implementation; independent registered PDS harness',
            'hardware_tested':False,'board_integrated':False,'rtl_run':str(rtl),'rtl':rtl_result,'model':model,
            'benchmarks':benchmarks,'pds_final':pds_result(pds),'pds_comparisons':[pds_result(base/name) for name in names],
            'current_rtl_sha256':source,'cache_model':str(base/'cache_round_robin_audit.json'),'extra_overflow_campaign':extra}
    # Check the production RTL hashes, excluding the optional observation harness
    # from the delivery set; it has its own hash in the native manifest.
    native_manifest={r['path']:r['sha256'] for r in result['pds_final'].get('source_manifest',[])}
    result['pds_source_matches_current']=all(native_manifest.get(k)==v for k,v in source.items())
    result['offline_checks_passed']=bool(rtl_result.get('passed')) and bool(model.get('passed')) and bool(extra.get('passed')) and result['pds_final']['internal_sta_passed'] and result['pds_source_matches_current']
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'report':str(output),'offline_checks_passed':result['offline_checks_passed'],'hardware_tested':False}))


if __name__=='__main__':main()
