"""Expose incomplete PLC delay coverage instead of treating it as routed STA."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    """Preserve path identities and zero-delay counts for the handoff."""
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--diagnostic',required=True,type=Path)
    a=ap.parse_args();root=a.diagnostic.resolve()
    runs=json.loads((root/'result.json').read_text());rows=[]
    for run in runs:
        assert run['native_exit']==0 and run['plc_intact'] and run['sources_intact']
        report=Path(run['output'])/'report_timing/pango_video_system.rtr'
        text=report.read_text(errors='replace')
        delays=re.findall(r'Logic: [^\n]*?Route: ([\d.]+)ns',text)
        paths=[]
        for block in re.split(r'(?=Startpoint\s*:)',text):
            if 'Path Type   : max' not in block[:1000]:continue
            slack=re.search(r'Slack \([^\n]+?\)\s+(-?[\d.]+)',block)
            route=re.search(r'Route: ([\d.]+)ns',block)
            group=re.search(r'Path Group\s*:\s*([^\n]+)',block)
            if slack and route and group and group[1]=='ddrphy_sysclk':
                paths.append(dict(slack_ns=float(slack[1]),data_route_ns=float(route[1]),
                    start=block.splitlines()[0],end=block.splitlines()[1]))
        paths.sort(key=lambda x:x['slack_ns'])
        rows.append(dict(original=run['original'],report=str(report),
            sha256=hashlib.sha256(report.read_bytes()).hexdigest(),
            data_paths=len(delays),zero_data_route_paths=sum(float(x)==0 for x in delays),
            ddr_setup_examples=paths[:3],plc_intact=run['plc_intact']))
    result=dict(routed_signoff=False,can_explain_placer_wns=False,reports=rows,
        limitation='Most reported data paths have zero route delay in the incomplete PLC. Do not replace placement estimates or final routed STA with these values.',
        official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Timing_Analyzer_User_Guide.pdf physical pages 5-7; installed native_flow_help/timing_help.log')
    (root/'delay_coverage.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(root/'delay_coverage.json')


if __name__=='__main__':main()
