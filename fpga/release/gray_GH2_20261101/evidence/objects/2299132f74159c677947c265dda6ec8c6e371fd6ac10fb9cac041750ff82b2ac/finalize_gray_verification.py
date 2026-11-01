"""Review completed gray candidates and publish a pre-route verification record."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re

from combined_cdc_gate import verify_revision
from review_gray_candidates import inspect


def read(path):
    """Read completed evidence; incomplete jobs must not receive a final report."""
    return json.loads(path.read_text(encoding='utf-8'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def timing_summary(build):
    """Keep estimated setup and reported hold/removal violations distinct."""
    text=(build/'synthesize/pango_video_system.snr').read_text(errors='replace')
    clocks={}
    for line in text.splitlines():
        match=re.match(r'^\s*(\S+)\s+[\d.]+\s+MHz\s+[\d.]+\s+MHz\s+[\d.]+\s+[\d.]+\s+(-?[\d.]+)',line)
        if match:
            clocks[match[1]]=float(match[2])
    violations=[]
    for block in re.split(r'(?=Startpoint\s*:)',text):
        slack=re.search(r'Slack \(VIOLATED\)\s+(-?[\d.]+)',block)
        start=re.search(r'^Startpoint\s*:\s*([^\n]+)',block)
        end=re.search(r'Endpoint\s*:\s*([^\n]+)',block)
        kind=re.search(r'Path Type\s*:\s*([^\n]+)',block)
        if slack and start and end:
            violations.append(dict(start=start[1].strip(),end=end[1].strip(),
                kind=kind[1].strip() if kind else 'unknown',slack_ns=float(slack[1])))
    if 'processing_clk' not in clocks:
        raise ValueError('Missing processing setup estimate')
    return dict(estimated_setup_ns=clocks,reported_violating_paths=violations,
                routed_signoff=False,reported_paths_only=True)


def main():
    """Require finished MAP/CDC gates and immutable sources before publishing."""
    f=Path(__file__).resolve().parents[1]
    root=f/'build/gray_candidates_native_20261031'
    queue=read(root/'run_1510/state.json')
    final=read(root/'BE_after_BCD_cdc/state.json')
    if any(s['status']!='ALL_MAP_COMPLETE_REVIEW_REQUIRED' for s in (queue,final)):
        raise RuntimeError('Native verification is still incomplete')
    candidate=f/'build/reader_full_chunks_20261031/BE_cdc_verified_candidate'
    proof=f/'build/reader_full_chunks_20261031/BE_working_candidate'
    functional=verify_revision(f,candidate,proof)
    audits={}
    for name,path in {
        'combined_functional':proof/'independent_functional_audit.json',
        'CD_functional':f/'build/verification_20261031/CD_functional_audit.json',
        'D_ROD_reset':f/'build/verification_20261031/D_rod_reset_final_review.json',
        'CDC_application':root/'BE_after_BCD_cdc/cdc_constraint_review.json',
    }.items():
        if not read(path).get('passed'):
            raise RuntimeError('Incomplete independent audit: '+name)
        audits[name]=dict(path=str(path),sha256=sha(path))
    items={**queue['candidates'],**final['candidates']}
    reviews={};timings={}
    for name,item in items.items():
        if item.get('status')!='MAP_COMPLETE_REVIEW_REQUIRED':
            raise RuntimeError('Incomplete MAP: '+name)
        syn=Path(item['synthesis']);mapping=Path(item['mapping'])
        reviews[name]=inspect(syn,mapping)
        # Keep known shared-pin diagnostics visible; a new diagnostic must be
        # reviewed rather than silently folded into the baseline statement.
        constraints=reviews[name]['constraints']
        if constraints['constraint_check']['diagnostic_counts']!={'ConstraintEditor-2002':33}:
            raise RuntimeError('Unexpected CCR diagnostics: '+name)
        if constraints['postsyn_constraint_gate'].get('command_count')!=10:
            raise RuntimeError('Expected ten consumed SCF commands: '+name)
        timings[name]=timing_summary(syn)
    manifest=read(candidate/'sources.json')
    mapping=Path(items['BE']['mapping'])
    if read(mapping/'sources.json')!=manifest:
        raise RuntimeError('Final MAP is not the selected candidate')
    # Live implementation identity is checked without requiring mutable release
    # authorization/configuration files to equal their historical frozen copies.
    live_names=[n for n in manifest if n.startswith(('rtl/','constraints/'))]
    if not all(sha(f/n)==manifest[n] for n in live_names):
        raise RuntimeError('Live RTL/constraint drift')
    if timings['BE']['estimated_setup_ns']['processing_clk']<0:
        raise RuntimeError('Final processing setup estimate regressed below zero')
    summary=dict(status='FUNCTIONAL_SYN_MAP_VERIFIED_PRE_ROUTE',
        checked_at=datetime.now().astimezone().isoformat(),candidate=str(candidate),
        manifest_sha256=sha(candidate/'sources.json'),functional_revision=functional,
        live_implementation_files_matched=len(live_names),audits=audits,
        candidates=reviews,timing=timings,placement_started=False,
        routed_timing_verified=False,bitstream_generated=False,hardware_tested=False,
        comparison_limit='Final BE also repairs CDC constraints; its delta is not a pure isolated E measurement.')
    out=f/'build/verification_20261031/final_summary.json'
    temp=out.with_suffix('.tmp')
    temp.write_text(json.dumps(summary,indent=2),encoding='utf-8');temp.replace(out)
    # This report records the exact stage, including residual estimated timing
    # violations; successful software checks cannot become routed signoff.
    rows=[]
    for name in ('B','C','D','BE'):
        r=reviews[name]['mapping_resources'];slack=timings[name]['estimated_setup_ns']['processing_clk']
        rows.append(f'| {name} | {r["LUT"]:g} | {r["FF"]:g} | {r["APM"]:g} | {r["DRM"]:g} | {slack:+.3f} |')
    report='\n'.join([
        '# 当前灰度组合版验证完成记录','',
        '本轮功能、SYN/MAP及约束一致性验证完成。尚未布局布线，没有布线后STA、位流或实板验收。','',
        '当前工作区对应BE＋精确CDC修正；C/D保留为独立实验，未合入。','',
        '候选含义：B为姿态解算结果bank复用；C为writer数据清零裁剪；D为安装矩阵本地读取与工作矩阵LUTRAM映射；E为RAW reader整32字节块优化。BE是当前B与E的组合，另含本轮CDC约束修正。','',
        '| 候选 | MAP LUT | MAP FF | APM | DRM | processing综合setup(ns) |',
        '|---|---:|---:|---:|---:|---:|',*rows,'',
        'MAP基线为38275 LUT、42632 FF、154 APM、71.5 DRM；不能与SYN FF混比。','',
        '当前组合相对基线MAP减少356 LUT、375 FF，APM/DRM不变。D虽资源更少，但尚未与E组合并完成整机验证；没有将独立实验结果自动并入当前版本。','',
        '## 功能证明','',
        '- 当前组合完整1080p：3新帧、5次旧帧重复，16588800像素，failed=0、underflow=0；排空换矩阵及旧帧保持通过。',
        '- FPGA原始pitch/yaw解算：数值、161例逐位差分、UART及几何集成证明与当前solver字节一致；视频顶层本身不例化solver。',
        '- RAW reader：450000次差分检查、15组DMA adapter场景、2073600字节完整网络回传通过。',
        '- reader综合网表核验：256位输出直接来自payload寄存器，固定整块模式的尾mask及动态长度逻辑消除；reader含子模块较B减少254 LUT、32 FF，握手控制仍保留。',
        '- C专项与完整视频通过；D差分及新增54个ROD写入前后复位点通过。D未单独运行完整视频，也未合入当前组合。','',
        '## 原生验证与时序边界','',
        '- SYN/MAP原生退出成功、冻结源哈希与当前RTL/约束对应；10条SCF实际加载，CCR零错误，保留原33条share-pin诊断。',
        '- 新增ready_sync/active→paused_meta精确6ns datapath-only及首跳hold例外，MAP实际加载；后级paused_sync没有新增例外。旧首跳异步hold违规未再报告。',
        '- 综合报告仍有DDR内部hold估计；phase FSM removal的SYN报告与MAP后的10条精确SCF阶段不同。不能将processing正余量称为全芯片时序通过，须后续PnR min/max STA。',
        '- 最终组合含reader及CDC修正，其资源差不能全部归因于reader。没有复用旧PLC，也没有开启新PnR scope。','',
        '## 精确结果位置','',
        f'- 当前候选：`{candidate.as_posix()}`',
        f'- SYN：`{items["BE"]["synthesis"]}`',
        f'- MAP：`{items["BE"]["mapping"]}`',
        f'- 汇总与源哈希：`{out.as_posix()}`',
        f'- CDC终结核验：`{(root/"BE_after_BCD_cdc/cdc_constraint_review.json").as_posix()}`','',
        '剩余工作是另行审阅并启动布局布线、检查实际min/max STA及实板功能；本次没有宣称这些阶段已完成。',''])
    (f/'reports/当前灰度组合版验证完成_20261031.md').write_text(report,encoding='utf-8')
    print(out)


if __name__=='__main__':
    main()
