"""Save the selected recovery fix and terminal proofs, excluding live tasks."""
from pathlib import Path
import hashlib,json,subprocess,sys,zipfile
S=Path(__file__).parent;R=S.parents[3];F=R/'fpga';B=F/'build/full_integration_20261013'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inplace(p,t):
    # Existing GUI handles can forbid truncating opens; retain the same inode
    # and explicitly truncate only after successfully writing the new bytes.
    with p.open('r+b') as stream:stream.write(t.encode('utf-8'));stream.truncate()
readme=F/'experiments/proc150/README.md';t=readme.read_text(encoding='utf-8')
t=t.replace('2026-10-20 04:57','2026-10-20 05:15').replace('13项选定修改','14项选定修改')
t=t.replace('主设计尚未合入，需原帧池组成的完整帧确认。','05:07已单文件合入主设计；原帧池组成20项回归、完整1080p/主机解码与原始快照字节一致性均通过。')
t=t.replace('预算20分钟，未终结前不计通过。','原20分钟总预算TIMEOUT，Compile完整、SYN数据库未保存完整；复用完整Compile单独SYN1200秒/MAP600秒，当前仍未终结。')
inplace(readme,t)
status='''
## 2026-10-20 05:15 检查点

主设计已选择14项修改，仍为125MHz；最后单文件修正上一帧cache fault残留导致下一帧误报失败。20项回归、完整1080p控制/快照/显示、主机8888报文/12441600图像字节通过，原始datagrams和descriptor哈希均与旧基线一致。六类完成故障及逐帧恢复同步1组/双时钟3组通过。来源与备份见session_20261019/geometry_recovery_promotion_20261020和recovery_finalist。

150MHz最终无帧池候选20项回归sim_20261020_050821_373307通过，完整模型verilator_20261020_044250_609135仍运行，不能计为PASS。上一未修复tile全帧verilator_20261020_042011_025150实际2400秒TIMEOUT，保留失败结果。

板级board_20261020_044551_218517总预算1200秒TIMEOUT：Compile完成12m31s，综合进入保存DB但未完成。未经完整保存的syn.adf不复用、不计通过。安装版help确认force_to_run/input_db_file后，从完整Compile DB启动proc150_board_mapping_20261020_050951_080852，仅SYN固定1200秒、MAP固定600秒，不含PnR/位流。初次SNR仅诊断，不作为完整MAP签核。

真实账户最近剩余34%；到10%停止优化。整体PnR和位流门槛保持关闭。最新已推送bc533f84；本检查点提交/推送成功后以Git回执为准。下一小时汇报05:48。
'''
for name in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md']:
    p=F/'reports'/name;inplace(p,status+'\n'+p.read_text(encoding='utf-8'))
host=R/'host/reports';a=host/'.gitattributes'
with a.open('a',encoding='utf-8') as out:out.write('\nfpga_rgb_vectors_20261020_050710_104188* -text\n')
board=B/'board_20261020_044551_218517';zpath=board/'native_terminal_0515.zip';members={}
with zipfile.ZipFile(zpath,'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(board.rglob('*')):
        if p.is_file() and p.suffix in ('.adf','.snr','.vm','.pcf'):
            n=p.relative_to(board).as_posix();z.write(p,n);members[n]=dict(sha256=sha(p),bytes=p.stat().st_size,
                completion='COMPLETE_COMPILE' if n.startswith('compile/') else 'INCOMPLETE_TIMEOUT_DIAGNOSTIC')
with zipfile.ZipFile(zpath) as z:
    assert z.testzip() is None and all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
zm=board/'native_terminal_0515_manifest.json';zm.write_text(json.dumps(dict(archive_sha256=sha(zpath),members=members),indent=2))
models=[B/n for n in ['verilator_20261020_043518_857947','verilator_20261020_042714_357386','verilator_20261020_042011_025150']]
proofs=models+[B/'sim_20261020_050821_373307']
trees=[S/'geometry_recovery_promotion_20261020',S/'recovery_finalist',S/'native_map_help_0510',board,
       host/'fpga_rgb_vectors_20261020_050710_104188_companions']
files=[Path(__file__).resolve(),S/'promote_recovery_0510.py',S/'probe_native_map_help_0510.py',S/'refresh_proc150_readme_0457.py',
       F/'rtl/geometry/geometry_rgb_pipeline.sv',F/'config/implementation_readiness.json',readme,zpath,zm,a,
       host/'fpga_rgb_vectors_20261020_050710_104188.json']
files += [F/'scripts'/n for n in ['build_video_system.py','sim_full_integration.py','continue_proc150_mapping.py']]
files += [F/'reports'/n for n in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md']]
for model in models:
    for n in ['snapshot_datagrams.bin','snapshot_descriptors.bin','CMakeLists.txt','build_anchor.cpp']:
        if (model/n).exists():files.append(model/n)
subprocess.run([sys.executable,str(F/'scripts/freeze_regional_checkpoint.py'),'--label','0515','--session',str(S),
    '--proof',*map(str,proofs),'--input-tree',*map(str,trees),'--file',*map(str,files)],cwd=R,check=True)
