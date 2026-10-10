# RGB33 标定候选交付记录

2026-10-10。用户指定将本次本地标定数据与两份 PDF 同步 GitHub，供 Jetson 最终上位机使用。源文件来自 `D:/XDU/concept/26-FPGA-Pango/host/reports/rgb33-calibration-20261010/`，14 个交付原件按字节复制并核对 SHA-256，没有改写源报告。

本目录 `.gitattributes` 仅对这14个原件禁用 Git 文本换行转换，确保 Windows 提交和 Linux/ARM64 拉取的字节哈希一致，不改变仓库忽略规则或系统 Git 配置。不要重新序列化 JSON/YAML 后仍沿用原哈希。

## 内容与范围

- `report.pdf`：完整 33 视图标定报告，包含角点覆盖、误差和软件参考图。
- `tuning-guide.pdf`：参数说明、FOV 扫描和补采建议。
- `calibration-results.json`：全量角点、来源声明、两模型及留一验证记录。
- `fisheye_equidistant.json/.yml/.sha256`、`pinhole_k1_k2_p1_p2.json/.yml/.sha256`：分别保留两种模型，不混用系数。
- `fisheye-preview-rgb33.json`：现有 PC 软件参考页面的导入文件，不自动下发 FPGA。
- `preview-coordinate-reference.json`、`tuning-fov-sweep.json`、`per-view-errors.csv`：软件坐标参考、FOV 数值和逐图误差。
- `delivery-verification.json`：原报告生成时的检查记录，不是本次再次执行的算法或板级测试。
- `SHA256SUMS`：上述 14 个原件的交付哈希。

本次未上传原始 `.rgb/.raw`、实测视频及独立派生 PNG/JPEG 图集。它们仍留在原机，原图哈希和角点在 JSON 中保留，PDF 自带的报告插图随用户指定报告一起交付。仅凭此包不能重新运行原像素角点检测；如需完整复现，应另行安全转移原始 RGB 归档并核对哈希。未复制依赖外部图片的 HTML/Markdown 原报告，避免交付断链页面。

## 联调补充，不覆盖原结论

推荐模型为 `fisheye_equidistant`，尺寸 1920×1080，输出 HFOV 100°。训练 RMS 0.362857 px、留一合并 RMS 0.388666 px 是原报告的软件结果；没有独立最终测试图，没有本次 FPGA 图像验证。

原报告按旧 Brown 针孔接口写有鱼眼“不兼容”与 `fpga_compatible=false`，这些原始声明不修改。现有 main 的 `geometry_lens_lut.v` 已有四系数鱼眼 model=2，`GeometryProfile.from_preset` 可以无溢出编码本组值。本次另建[FPGA 联调参数记录](../../config/calibration/fpga-fisheye-rgb33-20261010.json)，明确区分模型语义、离线编码和未执行的硬件验证；不把软件 RMS 当成 FPGA 实测误差。

Jetson 接入步骤、最终控制器职责及验收边界见[Jetson RGB33 标定接入说明](../../docs/Jetson_RGB33标定接入说明.md)。
