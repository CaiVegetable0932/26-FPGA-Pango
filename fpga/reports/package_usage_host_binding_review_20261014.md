# 候选位流 usage/PC 控制指南与冻结host来源复核

2026-10-14 21:26。初始限定只读检查发现packager的host来源绑定缺口，根代理随后授权本agent修正 `host/scripts/verify_fpga_rgb_vectors.py`，由根代理修正packager。未改任何FPGA RTL/native来源或运行PDS，未生成ZIP/发布包/占位位流，未连接硬件。

## 判定及已修正问题

原 `package_video_system.py:116–119`（修改前SHA `2c0142249606e24bd20d81d36e859115369ab87de9e10d6d5882391380781622`）从项目live路径读八个host模块和验证脚本；历史host报告仅含向量input_sha256。打包时companion hash能说明交付字节，不能证明它们就是历史PASS实际使用的解码器。原FPGA PC指南已经正确来自 `build/source/config/integration/PC_RGB_CONTROL.md`，没有同样的live来源问题。

已实际修正host验证入口：

- 原调用先把脚本自身与八个模块按 `host/...` 完整相对目录复制到一个新 `host/reports/*_companions` 根，保存精确九项SHA与原始来源记录。
- 使用 `python -I -B` 独立worker，实际执行快照内脚本。worker检查八个真实module.__file__和自身__file__恰为冻结路径，再读取向量；不是只给live验证附上新SHA。
- worker前后核对九文件实际SHA，并把新报告写在快照旁原host/reports。旧历史报告不修改、不伪造绑定，失败运行保留worker日志。
- 注释同步说明导入闭包、实际冻结验证、旧报告边界与无硬件IO。没有执行网络/串口收发。

实际新D报告：[fpga_rgb_vectors_20261014_212339_734188.json](../../host/reports/fpga_rgb_vectors_20261014_212339_734188.json)。通过8888包、12441600 RGB字节、两份同源descriptor；hardware_tested=false、HDMI来源仍unverified。输入向量保持实际两项原SHA：

| 向量 | SHA256 |
| --- | --- |
| snapshot_datagrams.bin | f42a234194de8b85d182f6e4d1ae089d3f02266d8e1918fb0a027853e5c01669 |
| snapshot_descriptors.bin | 1f7791da07114603493586ee16181dae243ab13a38b9085d15da53d887666366 |

快照绝对根：`D:/XDU/concept/26-FPGA-Pango/host/reports/fpga_rgb_vectors_20261014_212339_734188_companions`。脚本SHA `dffc91083246b150c718a33f03b4d4e98e558725a4affa15dd388e26bd403738`。报告字段为 `companion_snapshot_directory`、精确九项 `companion_files_sha256`、`verification_script_path`、`companion_snapshot_intact=true`、`verification_environment`及精确八项`companion_import_paths`。

八个import keys：`pango_video`（__init__.py）、`pango_video.fpga_rgb_control`、`pango_video.raw8_boot`、`pango_video.protocol`、`pango_video.cli`、`pango_video.reassembly`、`pango_video.receiver`、`pango_video.storage`。所有路径实际属于该冻结根，内容SHA同报告。

## 导入闭包与指南一致性

闭包静态检查：fpga_rgb_control→raw8_boot→cli/protocol；cli→protocol/reassembly/receiver/storage；后三者仅依赖其中模块及标准库。`receiver.py:151–156`的linux_udp是可选运行期加速，并捕获ImportError回落recvfrom_into；它不影响离线导入，未假装包内含Linux原生加速实现。八文件足够完成此离线解码/API闭包，未宣称其为完整硬件控制客户端。

冻结指南与当前D FPGA接口核对：PC V1/0x71外层、0x90/95/96/97分页、0x92 mode、0x93 snapshot、0x94全17定点词+CRC32、616bit metadata+descriptor、RGB type2/3及紧凑导出尺寸与现有编解码一致。D指南SHA为 `d321d440e739e114b1550b5f98fa55418bf2138906a81deab3f32d4146a80968`；live指南本次同SHA，但packager仍取冻结源。指南介绍纯API与协议，没有承诺直接打开串口的CLI。

计划证据布局可从解压根运行：

```text
python -B usage/host/scripts/verify_fpga_rgb_vectors.py --run simulation --width 1920 --height 1080
```

这条命令使用ZIP中的九文件+两份simulation向量，在usage/host/reports下产生一份新的冻结离线报告，不发送数据。实际等价目录测试使用额外 `-I`：`fpga/build/package_usage_frozen_audit_20261014_212657_184680/audit_result.json`记录exit0及完整PASS。没有生成ZIP/位流；仅建立相同目录结构的审查副本。raw8_boot的 `--help` 和verification `--help` 也已在隔离八模块布局通过；26份boot/mode/snapshot/readpage/geometry纯编码CRC检查及离线向量检查通过，socket构造在该纯API测试中禁止。

## 根代理packager修正复核

当前packager的 `verified_host_companions()`要求精确九项、快照位于host/reports、snapshot_intact=true、自身脚本路径及八个实际import路径匹配，对每份实际文件SHA校验后保留bytes用于ZIP。host报告bytes同样一次读取后归档；两个向量要求精确2项。指南单独来自原生冻结来源。因而当前使用上述新报告时，usage不能从live host重新取代码。

本agent只调用此纯校验函数，没有执行packager main或模拟任何native通过。真实新报告接受、九payload hash一致；下列四项拒绝测试均通过：旧未绑定历史报告、snapshot_intact=false、错误codec SHA、把cli import路径改成live源。结果在 `fpga/build/package_usage_audit_20261014_212105_953662/frozen_companion_gate_tests.json`。旧D host报告仍保持未绑定，未替换其历史字节。

后续实际打包仍须等待真实PnR、同数据库min/max STA和bitgen门禁通过；本次仅完成host来源/离线使用审查及修正，不代表新位流已经存在或硬件视频已验证。
