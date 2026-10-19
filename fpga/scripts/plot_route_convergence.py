"""Snapshot native route convergence without claiming routed/STA success."""
import argparse
import csv
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
from route_supervisor import route_iterations


def main():
    """Keep the plotted native log bytes, round CSV and a standalone figure."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build',type=Path,required=True)
    parser.add_argument('--record',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--label',help='Explicit experiment label shown on the snapshot')
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    build,record,output=args.build.resolve(),args.record.resolve(),args.output.resolve()
    if (not build.is_relative_to(fpga/'build') or not record.is_relative_to(fpga/'build')
            or not output.is_relative_to(fpga/'reports')):
        raise ValueError('Route data and figures belong inside FPGA build/reports')
    source=max(build.glob('resume_*/place_route.log'))
    payload=source.read_bytes()
    rounds=route_iterations(payload.decode(errors='replace'))
    if not rounds:
        raise ValueError('No completed detailed-route rounds are available')
    snapshot=record.with_suffix('.native.log')
    snapshot.write_bytes(payload)
    best=None
    for row in rounds:
        best=row['unrouted'] if best is None else min(best,row['unrouted'])
        row['best_unrouted']=best
        native_dump=build/'place_route/CongestionNetInfo'/('CongestionNetInfo_'+str(row['iteration'])+'.txt')
        row['native_dump_utc']=(datetime.fromtimestamp(native_dump.stat().st_mtime,timezone.utc).isoformat()
                                if native_dump.exists() else None)
    with record.with_suffix('.csv').open('w',newline='',encoding='utf-8') as stream:
        writer=csv.DictWriter(stream,fieldnames=list(rounds[0]))
        writer.writeheader();writer.writerows(rounds)
    record.write_text(json.dumps(dict(
        observed_at=datetime.now(timezone.utc).isoformat(),build=str(build),source_log=str(source),
        source_log_sha256=hashlib.sha256(payload).hexdigest(),frozen_plot_log=str(snapshot),
        rounds=rounds,routed_signoff=False,timing_signoff=False,
        note='Native CPU values are per iteration. No successful baseline or speedup claim.'),indent=2)+'\n')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.ticker import MaxNLocator
    fig,axes=plt.subplots(2,1,figsize=(9,6.5),sharex=True,layout='constrained')
    x=[r['iteration'] for r in rounds]
    axes[0].plot(x,[r['unrouted'] for r in rounds],color='#17628b',marker='o',markersize=3)
    axes[0].set_ylabel('Unrouted subnets');axes[0].set_ylim(bottom=0)
    axes[0].set_title((args.label or build.name)+' — detailed routing snapshot',loc='left',fontweight='bold')
    axes[0].annotate(f"Latest: {rounds[-1]['unrouted']:,}",
                     xy=(x[-1],rounds[-1]['unrouted']),xytext=(-105,15),textcoords='offset points')
    axes[1].plot(x,[r['cpu_seconds'] for r in rounds],color='#b36112',marker='o',markersize=3)
    axes[1].set_ylabel('Native CPU seconds / round');axes[1].set_xlabel('Detailed-route iteration')
    axes[1].set_ylim(bottom=0);axes[1].xaxis.set_major_locator(MaxNLocator(integer=True))
    for axis in axes:
        axis.grid(alpha=0.2);axis.spines[['right','top']].set_visible(False)
    fig.suptitle('Snapshot only: routing completion and min/max STA are still required',fontsize=10,color='#555555')
    fig.savefig(output,dpi=180);plt.close(fig)
    print(json.dumps(dict(rounds=len(rounds),latest_unrouted=rounds[-1]['unrouted'],figure=str(output))))


if __name__=='__main__':
    main()
