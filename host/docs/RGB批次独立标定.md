# RGB批次独立标定与完整报告

2026-10-10，按用户提供的11张RGB独立拟合，不启动上位机或修改已有标定组。
本批最终实测配置为 **15列×9行内角点、15 mm格宽**，对应16×10方格。
输入的1920×1080 RGB888尺寸与上位机同哈希归档记录一致，每图6,220,800字节。

## 复现命令

先准备项目标定环境，再安装报告依赖（只需一次）：

```powershell
python host/scripts/setup_calibration.py
& host/build/calibration-venv/Scripts/python.exe -m pip install -r host/requirements-calibration-report.txt
```

在项目根目录执行，按实际存放位置修改input-dir：

```powershell
& host/build/calibration-venv/Scripts/python.exe -X utf8 -B host/scripts/calibrate_rgb_dataset.py `
  --input-dir 'C:/Users/ROG/Downloads' --glob 'image (*.rgb' `
  --width 1920 --height 1080 --cols 15 --rows 9 --square-mm 15 `
  --report-dir host/reports/rgb11-calibration-20261010 `
  --archive-dir host/data/standalone-calibration/rgb11-20261010
```

Linux在同一OpenCV环境运行相同脚本，替换Python路径和输入路径即可。
PDF优先嵌入Windows微软雅黑字体，其他环境使用ReportLab中文CID字体回退；
跨平台字体和排版仍需本机检查。`--no-pdf`只生成HTML/Markdown与数值记录。
`--fov`设置两模型共用的理想针孔输出水平视场，默认100°，仅用于软件对照。

宽高、角点行列、格宽都是必填，不从无头RGB长度猜测图像形状。
不增加输入行填充或RGB/BGR互换；输入为紧密RGB888，输出PNG才转成OpenCV BGR编码。

## 处理与验证

保存原字节、文件名、哈希和同哈希来源声明；SB先做原分辨率完整角点检测，
必要时尝试精细/穷举和传统亚像素检测。重复图、尺寸冲突及已知TEST/MOCK、
声明为S2/S3的来源不进入拟合。未知身份保持unverified；不推断同帧配对。

至少4张完整有效视图才尝试小批次求解和逐图留一验证。鱼眼模型固定skew=0，
针孔模型固定k3=0、拟合k1/k2/p1/p2。每轮去掉一整张图，仅用剩余图拟合K/D，
留出图仅估计姿态。选模按合并留一RMS；没有再设置外层独立测试集，
不能把选模用的交叉验证误差称为完全独立最终泛化误差。

本脚本允许11张的小样本候选拟合，工作台25拟合/3独立验证的门槛未调整。
原有21×21/10 mm组保持原样，最新实测几何只用于这次独立批次。

## 产物

- `report.pdf`、`report.html`、`report.md`：中文完整报告、逐图误差、参数敏感性、覆盖、对照、有效域、来源与验收边界。
- `calibration-results.json`：全部输入、135点坐标、模型、22个留一折、每图派生姿态与统计。
- `fisheye_equidistant.json/.yml/.sha256`：鱼眼k1/k2/k3/k4。
- `pinhole_k1_k2_p1_p2.json/.yml/.sha256`：针孔k1/k2/p1/p2，k3=0。
- `per-view-errors.csv`、`coverage.png`、`loo-errors.png`：可复核数值与图表。
- `corners-*.png`、`comparison-*.jpg`、`fisheye/pinhole-*.png`及有效采样掩码：派生诊断与原分辨率离线矫正。
- archive-dir中的`.rgb`与`manifest.json`：真实原始字节证据；已有不同字节的同名归档拒绝覆盖。

参数始终标记candidate_unverified、measurement_ready=false、hardware_applied=false。
鱼眼四系数不能写入当前针孔FPGA寄存器；针孔compatible仅表示模型语义。
纸板平整度、实测格宽、焦点、边缘精度和输入与板端S1等价性尚需独立确认。
软件矫正、棋盘行列内诊断、姿态和人工距离均不冒充MTF/SFR、IMU或硬件帧率验收。

## 本轮结果与软件检查

本机11图全部检测135点。鱼眼训练RMS 0.347385 px，留一合并RMS 0.386637 px；
针孔训练RMS 0.920500 px，留一合并RMS 1.153820 px。原图和归档哈希逐项一致。
采集图像及PDF/测试报告留在本机，本轮只提交实现、依赖、复验测试与本说明。

新增测试使用已知K/D的独立解析投影视图验证恢复与留一误差、零畸变恒等映射、
邻域边界、重复图排除、归档冲突、尺寸冲突和文件自然排序。
复验用 `python -B host/scripts/test.py --report host/reports/offline-rgb-tests.json`，
需要与上位机测试一致的本机HTTP/UDP访问权限。

## 扩展至33张与调参说明（2026-10-10）

新增22张与前11张合并，仍为15×9内角点、15 mm格宽、1920×1080 RGB888。
使用同一命令，只将报告和归档目录改为`rgb33-calibration-20261010`和`rgb33-20261010`。
报告标题、缩略图说明及局限披露采用实际张数，大批次姿态表跨页并重复表头。
本机33张全部检测135点；鱼眼训练RMS 0.362857 px，留一合并RMS 0.388666 px；
针孔训练RMS 1.615492 px，留一合并RMS 1.849682 px。两批各自留一验证的样本分布不同，不能直接声称新增图必然降低误差。

本机扩展报告目录还保留`tuning-guide.pdf/html`、`fisheye-preview-rgb33.json`和`tuning-fov-sweep.json`。
调参指南比较旧手调、11张与33张真实拟合值，说明输入K/D与输出虚拟相机的区别、页面操作、故障排查和独立验证。
预览JSON采用页面`pango.fisheye-preview.v1`结构，供“导入调参 JSON”使用；完整模型JSON结构不同。
实测候选K/D保持固定，优先调整输出HFOV；100°软件逆映射有效采样率100%，139°约63.548%，这不是几何精度验收。
全部33张参与拟合；未补设外层独立测试集，仍需另采新图。不改写旧工作台组，不下发FPGA。
报告、原图及本机派生文档保持本地留存。
