"""Record the functional writer promotion without relaxing implementation gates."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
R=ROOT/'fpga/reports'
status='''
## 2026-10-20 03:58 写入器单文件合入

主设计从12项增加到13项：只合入 `fpga/rtl/memory/frame_pixel_writer.sv`，哈希 `dd089551cc79309e5175536c53f8efed36bfad7dba9438104365c6a1b5425f41`。完整signed乘积与两拍入口流水共同组成此候选；完整64位范围检查、像素精度、字节掩码、取消/排空均保留。每帧入口增加2拍，分段增加0拍。主设计实际时钟仍125MHz，整体布线/位流全部门槛未放行，整个方案尚未完成。

- 功能：50组独立语义/字节/范围/取消/延迟检查、20项回归全部通过。
- 三个区域seed11/7/13全部布通且内部多角STA通过，PnR分别50/63/58秒；没有时序合格的原始参考，不计算加速比。报告 `session_20261019/writer_three_seed_0358.json`。
- 完整1080p控制/快照/实际显示 `verilator_20261020_033308_185785` PASS，22809600显示像素失败0/下溢0，3新帧8重复帧；几何周期4073517/3796435/4114261与旧主设计相同。
- 主机报告 `host/reports/fpga_rgb_vectors_20261020_035641_996920.json` PASS，8888报文、12441600图像字节。datagrams/descriptor均与旧主设计逐字节相同，比较文件在模型目录 `snapshot_baseline_comparison.json`。
- 合入前逐项核对290项当前输入、候选、回归、模型、主机伴随源码和区域输入；只原子替换writer，保留 `session_20261019/writer_pipeline_promotion_20261020/before_frame_pixel_writer.sv` 及 `promotion.json`。新主输入清单 `session_20261019/writer_pipeline_finalist/sources.json`，其源码实体仍位于writer候选的冻结 `source/`。

150MHz实验第一组合的首个几何作业4470577个DDR周期，比125MHz基线更慢，不能采用；完整模型仍在收集后续场景。第二组合只把实验读CDC改为连续预取，生产显示读桥不变。八组读桥测试、三组真实几何字节检查及整机控制/快照小模型通过；精确150MHz完整帧模型 `verilator_20261020_035853_729207` 正在运行，未合入。

第二组合闭包 `proc150_video_model_20261020_035612_841416`，模型将TB时间精度提高到1fs，避免旧3.333ns半周期实际约150.015MHz造成期限口径误差。旧模型保留其真实周期与结果，不追溯重标。原型原生affine SYN LUT8846/FF7055/APM85/物理DRM43，读/写CDC各DRM4、邮箱19FF；不是projective配置或整机预算，尚无该域物理/CDC签核。

帧池8位计数分块11组差分及20回归通过，SYN LUT4190→4434、FF831→830、控制集25→21；区域A/B正在运行。其输入仍基于旧12项，后续若合入必须重新组成13项主设计并做完整验证，不能混用当前writer模型冒充组合通过。
'''
for n in ['route_optimization_progress_20261019.md','regional_verification_plan_20261019.md']:
    with (R/n).open('a',encoding='utf-8',newline='\n') as f:f.write('\n'+status)
handoff=R/'route_optimization_handoff_20261020.md';text=handoff.read_text(encoding='utf-8')
text=text.replace('更新时间：2026-10-20 03:48','更新时间：2026-10-20 03:58')
text=text.replace('## 主设计与完整证明',status+'\n## 主设计旧12项基线与完整证明')
text=text.replace('主设计仍为writer BRAM等11项基线加unpack局部捕获，共12项；','下述为03:58之前的12项基线：writer BRAM等11项加unpack局部捕获；')
text=text.replace('此后提交是诊断/实验/文档。','03:58已按上述证明再合入writer，主设计现为13项。')
text=text.replace('writer候选：','已合入的writer候选：')
text=text.replace('三seed、全帧及主机原始字节/身份验证全部过后，才考虑只替换writer单文件，保留原始备份，不能整目录覆盖。','三seed、全帧及主机原始字节/身份验证已全部通过并单文件合入，保留原始备份；不能整目录覆盖。')
handoff.write_text(text,encoding='utf-8',newline='\n')
print('WRITER_PROMOTION_STATUS_UPDATED')
