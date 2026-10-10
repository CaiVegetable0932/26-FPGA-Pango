"""Render a complete Chinese calibration record as HTML, Markdown and optional PDF.

Reports disclose candidate status, model semantics, cross-validation leakage and
unperformed hardware/image-quality checks instead of inventing acceptance results.
"""
from html import escape
import json
from pathlib import Path

FISH = "fisheye_equidistant"
LABELS = {FISH: "鱼眼等距 k1/k2/k3/k4", "pinhole_k1_k2_p1_p2": "针孔 k1/k2/p1/p2（k3=0）"}
SOURCES = [("OpenCV 4.13 鱼眼模型", "https://docs.opencv.org/4.13.0/db/d58/group__calib3d__fisheye.html"),
           ("OpenCV 4.13 相机标定", "https://docs.opencv.org/4.13.0/d9/d0c/group__calib3d.html")]


def number(value, digits=5):
    """Unknown measurements remain labelled unknown, including unavailable folds."""
    return "未测 / 不可用" if value is None else f"{value:.{digits}f}"


def sections(result):
    """Build one source of report text and tables, shared by all delivery formats."""
    cfg, inputs = result["config"], result["inputs"]
    models = [m for m in result["models"] if "K" in m]
    best = next((m for m in models if m["model"] == result["selected_model"]), None)
    summary = (f"{len(inputs)}张输入中{result['accepted_count']}张完整检测到{cfg['cols'] * cfg['rows']}个内角点。"
               f"本次采用{cfg['cols']}列×{cfg['rows']}行内角点、{cfg['square_mm']:g} mm实测格宽。")
    if best:
        summary += (f"按逐张留出验证的合并RMS，{LABELS[best['model']]}表现较好：训练RMS "
                    f"{best['rms_px']:.6f} px，留一验证RMS {best['loo_pooled_rms_px']:.6f} px。"
                    "两套真实图像拟合参数均已保存，结果是小样本候选标定，不是赛题最终验收。")
    else:
        summary += "有效视图不足或求解/验证未全部完成，没有可靠候选模型；请查阅逐图记录。"
    blocks = [dict(title="1. 结论与范围", paragraphs=[summary,
        "原始RGB字节保留且逐项校验；软件只生成离线参考，没有启动采集、修改旧标定组或下发FPGA参数。"
        "鱼眼的第三、第四系数是k3/k4，不能写成针孔p1/p2。"], tables=[])]
    blocks.append(dict(title="2. 输入、图卡与来源", paragraphs=[
        f"分辨率{result['image_size'][0]}×{result['image_size'][1]}，RGB888紧密行布局，行跨度{result['row_stride']}字节。"
        "RGB本身无文件头，本次宽高由显式命令参数及同哈希上位机记录共同核对，不靠字节数猜测。",
        f"{cfg['cols'] + 1}×{cfg['rows'] + 1}方格；相邻内角点{cfg['square_mm']:g} mm。"
        f"内角点坐标范围为0～{(cfg['cols'] - 1) * cfg['square_mm']:g} mm、0～{(cfg['rows'] - 1) * cfg['square_mm']:g} mm，Z=0。"
        "这是内角点跨度，不是板材外形尺寸。格宽影响外参尺度，通常不改变拟合K/D。",
        "输入哈希与原标定组记录匹配时，仅复用其尺寸及来源声明。历史配置中的21×21/10 mm不用于本次计算；"
        f"以本次指定的{cfg['cols']}×{cfg['rows']}/{cfg['square_mm']:g} mm为本次依据。旧记录及本次记录独立保存。",
        "原记录中的距离和光照均是人工声明，具体逐图数值保存在JSON来源记录，未独立复测、不作为内参约束，"
        "也不能当作实时传感器测量。相机/镜头编号、焦点、裁剪、缩放、ISP和S1等价性尚未物理核验。"],
        tables=[(["编号", "原文件", "字节数", "完整角点", "参与拟合"],
                 [[str(r["ordinal"]), r["name"], str(r["bytes"]), str(len(r["corners"])), "是" if r["accepted"] else "否"] for r in inputs])]))
    blocks.append(dict(title="3. 方法与验证设计", paragraphs=[
        "检测在原分辨率灰度图执行OpenCV SB与归一化；若失败再尝试穷举/精细SB及传统亚像素检测。"
        "只接受完整预期点数；不截取其他尺寸子网格冒充整板，不填补或手造角点。没有自动剔除高误差图。",
        "鱼眼模型：theta=atan(r)，theta_d=theta×(1+k1×theta²+k2×theta⁴+k3×theta⁶+k4×theta⁸)，固定skew为0。"
        "针孔模型：径向因子1+k1×r²+k2×r⁴，另加p1/p2切向项，固定k3为0。",
        "训练RMS=sqrt(所有训练角点的二维像素残差平方和/角点总数)。每图RMS按同一定义计算。"
        "留一验证每轮拿走一整张图，仅用其余图重拟合K/D，验证图仅估计姿态，再投影回原始畸变像素域。",
        "本批每个有效视图都恰好作为一次留出视图。合并留一RMS等于sqrt(各折RMS平方的平均值)，"
        "适用于本次各图点数相同的情况。选模使用了这些折，因此这些数值不是另外一个外层独立测试集的误差。",
        f"仅{result['accepted_count']}张而非工作台建议25～40张加3张独立验证图。本脚本允许小批次诊断候选拟合，不降低工作台原有25/3门槛。"
        "本次没有额外独立测试图、绝对距离真值、直线度标准或MTF/SFR验收数据。"], tables=[]))
    blocks.append(dict(title="4. 两种模型的参数与误差", paragraphs=[
        f"K的焦距与主点单位是输入像素，畸变系数无量纲。参数适用于当前{result['image_size'][0]}×{result['image_size'][1]}模式；改变裁剪、焦点或镜头需重新标定。"
        "允许按明确比例换算K的图像缩放不等于验证新的采集模式。"], tables=[(
        ["模型", "训练RMS px", "留一合并RMS px", "留一最大RMS px", "当前FPGA系数语义"],
        [["鱼眼" if m["model"] == FISH else "针孔", number(m["rms_px"]), number(m.get("loo_pooled_rms_px")),
          number(m.get("loo_max_rms_px")), "不兼容" if m["model"] == FISH else "k1/k2/p1/p2兼容"] for m in models])]))
    for m in models:
        K = m["K"]
        blocks.append(dict(title="参数 - " + LABELS[m["model"]], paragraphs=[
            "K = " + json.dumps(K, ensure_ascii=False),
            "; ".join(f"{name}={value:.12g}" for name, value in zip(m["distortion_order"], m["D"])),
            "fpga_compatible只表示系数模型语义；没有做硬件定点量化、范围检查、传输、回读或功能验证。"], tables=[(
            ["参数", "全量拟合值", "留一最小", "留一最大", "留一样本标准差"],
            [[n, number(v, 8), number(lo, 8), number(hi, 8), number(sd, 8)] for n, v, lo, hi, sd in zip(
                m.get("fold_parameter_range", {}).get("names", []),
                [K[0][0], K[1][1], K[0][2], K[1][2], *m["D"]],
                m.get("fold_parameter_range", {}).get("minimum", []), m.get("fold_parameter_range", {}).get("maximum", []),
                m.get("fold_parameter_range", {}).get("sample_std", []))])]))
        blocks[-1]["paragraphs"].append("留一参数波动是对删除单张图的敏感性，折之间有关联；不是95%置信区间，也不是制造公差。")
    accepted = [r for r in inputs if r["accepted"]]
    errors = []
    for i, r in enumerate(accepted):
        for m in models:
            fold = m["cross_validation"][i]
            errors.append([str(r["ordinal"]), "鱼眼" if m["model"] == FISH else "针孔",
                           number(m["training_errors_px"][i]), number(fold.get("rms_px")), fold.get("error", "完成")])
    blocks.append(dict(title="5. 逐图误差与视场覆盖", paragraphs=[
        "角点覆盖图在原始像素域绘制所有有效角点，不以板材白边面积替代角点覆盖。"
        "图卡在视场中心附近覆盖较密；周边没有足够实测角点约束，因此全画幅外推尤其边缘不可直接认证。",
        "每图灰度分位数、全图Laplacian方差、棋盘凸包占比、检测耗时和实际点坐标保存在完整JSON。"
        "全图清晰度代理值受背景影响，不是MTF50或SFR，也没有设置任意的通过阈值。"],
        tables=[(["图", "模型", "训练RMS px", "留出RMS px", "状态"], errors)]))
    if best and best.get("view_poses"):
        blocks[-1]["paragraphs"].append("另列较优模型下的固定K/D姿态估计：中心取全部内角点的几何中心，深度为相机Z分量，"
            "距离为光心到该中心的三维欧氏距离，倾角为板法线与相机光轴的锐角。它们是软件估计，不是镜头前端人工距离或IMU真值。"
            "完整Rodrigues旋转向量及首角点平移保存在JSON。")
        blocks[-1]["tables"].append((["图", "中心深度 mm", "光心到中心 mm", "法线倾角 °"],
            [[p["name"], number(p["centre_depth_mm"], 3), number(p["centre_ray_distance_mm"], 3),
              number(p["plane_normal_tilt_deg"], 3)] for p in best["view_poses"]]))
    line_rows = []
    for m in models:
        for e in m.get("line_errors", []):
            line_rows.append([e["name"], "鱼眼" if m["model"] == FISH else "针孔", number(e["raw"]["rms_px"]),
                              number(e["rectified"]["rms_px"]), number(e["rectified"]["max_abs_px"])])
    blocks.append(dict(title="6. 离线矫正与棋盘线诊断", paragraphs=[
        f"两种模型使用相同的理想针孔输出相机、同一输出尺寸、水平视场{result.get('software_output_fov_deg',100):g}°、单位旋转。"
        "使用逆映射和双线性插值，采样范围之外填黑；输出K和有效采样比例保存于参数JSON。"
        "这是明确裁剪后的PC对照，没有保证保留全部原视场或完全消除黑边。",
        "对每行、每列角点做正交最小二乘直线拟合，统计垂直距离。矫正后的坐标使用公共输出K。"
        "原始与输出是不同投影域、尺度不同，不可仅以数值比当作严格改善倍率。"
        "这些图参与了全量拟合，棋盘线统计是内部诊断，不是独立标准直线度验收。",
        "校正对照全部带PC参考标签。图卡的物理倾角依然保留；本次仅做静态镜头矫正，没有使用IMU或动态仿射变换。"
        "图中纸板有弯曲外观，平面假设及打印格宽应进一步用平整硬板和尺具核对。"],
        tables=[(["图", "模型", "原域线RMS px", "输出域线RMS px", "输出域最大 px"], line_rows)]))
    domains = []
    for m in models:
        output = m.get("software_output", {})
        angle = m.get("observed_ray_angle_deg", [])
        domains.append(["鱼眼" if m["model"] == FISH else "针孔", number(output.get("horizontal_fov_deg")),
                        number(100 * output["bilinear_valid_fraction"], 3) if output else "未测",
                        f"{angle[0]:.3f}～{angle[1]:.3f}" if angle else "未测",
                        number(m.get("fisheye_min_radial_derivative_observed_domain"))])
    blocks.append(dict(title="7. 有效域、限制与补采计划", paragraphs=[
        "有效采样掩码仅表示双线性插值的邻域在源图内，不代表该位置有标定精度保证。"
        "鱼眼径向导数仅检查从光轴到已检测角点最大光线角的采样域；不能推断整个200°视场的单调性或精度。",
        "建议把图卡固定在平整硬板上，实测多个格子的平均间距，锁定焦点和采集模式，补足25～40张多位置、多距离、"
        "两个方向倾斜的图，尤其靠近四边与四角。另采至少3张从未参与拟合或选模的独立图及直线/斜边测试图。",
        "针孔模型可作为当前FPGA受限模型的真实参数候选，但其误差需明确记录；不能把较低误差的鱼眼四系数写进"
        "针孔四寄存器。若采用鱼眼模型，需要对应硬件映射实现与实际验证。"],
        tables=[(["模型", "输出HFOV °", "双线性有效 %", "观测光线角 °", "鱼眼导数最小"], domains),
                (["验收项", "本次状态"], [["原图与135角点", "实际读取和完整检测"],
                 ["K/D及留一验证", "真实图像软件拟合；候选"], ["独立标准直线度 / MTF50 / SFR", "未执行"],
                 ["FPGA任意角度 / 插值 / 光照预处理", "未执行"], ["1080p30/60、延迟、LUT/寄存器/DSP、CDC", "未执行"]])]))
    blocks.append(dict(title="8. 复现、文件清单与数据完整性", paragraphs=[
        "运行环境：" + json.dumps(result["environment"], ensure_ascii=False),
        "复现命令参数：" + json.dumps(result["command"], ensure_ascii=False),
        "calibration-results.json保留全量输入、来源声明、角点、模型与全部留一折；两种模型单独JSON附SHA-256；"
        "另导出OpenCV YAML；per-view-errors.csv用于后续分析；corners-*.png保留角点叠加；fisheye/pinhole-*.png保留原分辨率软件矫正。",
        "原字节在host/data/standalone-calibration中归档，manifest.json保留原路径及哈希。"
        "本报告生成后再次核对原文件和归档字节，未改写Downloads原图。源帧号保持null，HDMI/网口配对未验证。"],
        tables=[(["图", "SHA-256"], [[r["name"], r["sha256"]] for r in inputs])]))
    for m in result["models"]:
        if "error" in m:
            blocks.append(dict(title="求解失败记录", paragraphs=[m["model"], m["error"]], tables=[]))
    return blocks


def html_table(headers, rows):
    """Escape all filenames and provenance text; no embedded untrusted HTML."""
    return "<div class='table'><table><thead><tr>" + "".join(f"<th>{escape(h)}</th>" for h in headers) + "</tr></thead><tbody>" + "".join(
        "<tr>" + "".join(f"<td>{escape(str(v))}</td>" for v in row) + "</tr>" for row in rows) + "</tbody></table></div>"


def create_reports(result, folder, pdf=True):
    """Write linked, printable report formats from the same measured data."""
    blocks = sections(result)
    title = f"{len(result['inputs'])}张RGB独立标定报告 · {result['config']['cols']}×{result['config']['rows']} / {result['config']['square_mm']:g} mm"
    html = ["<!doctype html><html lang='zh-CN'><meta charset='utf-8'><title>" + escape(title) + "</title><style>"
            "body{margin:0;background:#edf2f7;color:#172b40;font:16px/1.75 'Microsoft YaHei',sans-serif}"
            "main{max-width:1100px;margin:36px auto;padding:40px;background:white}h1{line-height:1.4}"
            "h2{margin-top:40px;border-top:3px solid #168286;padding-top:18px}p{overflow-wrap:anywhere}"
            ".tag{color:#9a431b;background:#fff0df;padding:14px}table{border-collapse:collapse;width:100%;font-size:13px}"
            "th,td{border:1px solid #d6e0ea;padding:7px;text-align:left;overflow-wrap:anywhere}th{background:#eef6f8}"
            ".table{overflow-x:auto}img{max-width:100%;height:auto}figure{margin:22px 0}figcaption{font-size:13px;color:#52677d}"
            "a{color:#116e9a}@media print{body{background:white}main{margin:0;padding:0}table{font-size:9px}"
            "h2{break-after:avoid}tr,figure{break-inside:avoid}}</style><main>",
            f"<h1>{escape(title)}</h1><p>{escape(result['created'])}</p><p class='tag'>真实图像拟合 / 小样本候选 / 未下发硬件</p>",
            "<p><a href='calibration-results.json'>完整JSON</a> · <a href='per-view-errors.csv'>逐图CSV</a>"
            + (" · <a href='report.pdf'>PDF报告</a>" if pdf else "") + "</p>"]
    markdown = ["# " + title, result["created"], "真实图像拟合 / 小样本候选 / 未下发硬件"]
    for block in blocks:
        html.append("<h2>" + escape(block["title"]) + "</h2>")
        markdown.extend(["", "## " + block["title"], ""])
        for p in block["paragraphs"]:
            html.append("<p>" + escape(p) + "</p>"); markdown.extend([p, ""])
        for headers, rows in block["tables"]:
            html.append(html_table(headers, rows))
            markdown.extend(["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"])
            markdown.extend("| " + " | ".join(str(v).replace("|", " / ") for v in row) + " |" for row in rows)
            markdown.append("")
        figures = []
        if block["title"].startswith("2."):
            figures = [("contact-sheet.png", "全部11张输入概览；这里只显示派生缩略图")]
        elif block["title"].startswith("5."):
            figures = [("coverage.png", "所有实际检测内角点的原始像素覆盖"), ("loo-errors.png", "每张图都曾被排除出其验证轮次的内参拟合")]
        elif block["title"].startswith("6."):
            figures = [(f"comparison-{r['ordinal']:02}.jpg", r["name"] + "：原图 / 鱼眼软件参考 / 针孔软件参考") for r in result["inputs"] if r["accepted"]]
        for filename, caption in figures:
            if (folder / filename).exists():
                html.append(f"<figure><img src='{filename}' alt='{escape(caption)}'><figcaption>{escape(caption)}</figcaption></figure>")
                markdown.extend([f"![{caption}]({filename})", ""])
    html.append("<h2>9. 算法资料</h2>")
    markdown.extend(["## 9. 算法资料", ""])
    for label, url in SOURCES:
        html.append(f"<p><a href='{url}'>{label}</a></p>"); markdown.append(f"- [{label}]({url})")
    html.append("</main></html>")
    (folder / "report.html").write_text("\n".join(html), encoding="utf-8")
    (folder / "report.md").write_text("\n".join(markdown), encoding="utf-8")
    if pdf:
        create_pdf(result, folder, blocks, title)


def create_pdf(result, folder, blocks, title):
    """Embed Chinese fonts and flow complete tables with repeated headers and page numbers."""
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_LEFT
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, PageBreak, KeepTogether
    font_path = Path("C:/Windows/Fonts/msyh.ttc")
    if font_path.exists():
        pdfmetrics.registerFont(TTFont("ReportCJK", str(font_path), subfontIndex=0))
    else:
        pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
    font = "ReportCJK" if font_path.exists() else "STSong-Light"
    body = ParagraphStyle("body", fontName=font, fontSize=9.2, leading=15, wordWrap="CJK", spaceAfter=8)
    heading = ParagraphStyle("heading", parent=body, fontSize=14, leading=20, textColor=colors.HexColor("#126b78"), spaceBefore=12, spaceAfter=12, keepWithNext=True)
    heading1 = ParagraphStyle("title", parent=heading, fontSize=23, leading=32)
    cell = ParagraphStyle("cell", parent=body, fontSize=7.6, leading=12, spaceAfter=0)
    small = ParagraphStyle("small", parent=body, fontSize=8, leading=13)
    width = A4[0] - 84
    doc = SimpleDocTemplate(str(folder / "report.pdf"), pagesize=A4, rightMargin=42, leftMargin=42,
                            topMargin=44, bottomMargin=44, title=title, author="Pango camera calibration")
    story = [Paragraph(escape(title), heading1), Paragraph(escape(result["created"]), body),
             Paragraph("真实图像拟合 / 小样本候选 / 未下发硬件", heading), Spacer(1, 8)]

    def figure(path, caption):
        """Scale each picture uniformly and keep room for readable captions."""
        from PIL import Image as PILImage
        with PILImage.open(path) as image:
            w, h = image.size
        scale = min(width / w, 460 / h)
        return [Image(str(path), width=w * scale, height=h * scale), Spacer(1, 5), Paragraph(escape(caption), small), Spacer(1, 12)]

    for block in blocks:
        if block["title"].startswith(("2.", "4.", "5.", "6.", "7.", "8.")):
            story.append(PageBreak())
        section_start = len(story)
        story.append(Paragraph(escape(block["title"]), heading))
        for p in block["paragraphs"]:
            story.append(Paragraph(escape(p), body))
        for headers, rows in block["tables"]:
            data = [[Paragraph(escape(str(v)), cell) for v in row] for row in [headers, *rows]]
            widths = [width / len(headers)] * len(headers)
            if headers == ["图", "SHA-256"]:
                widths = [width * .2, width * .8]
            table = Table(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
            table.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e9f3f5")),
                ("GRID", (0, 0), (-1, -1), .3, colors.HexColor("#bccbd7")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5), ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))
            if headers == ["图", "中心深度 mm", "光心到中心 mm", "法线倾角 °"]:
                # The compact pose table is a separate diagnostic; keep all
                # views together rather than leaving one isolated row behind.
                story.append(KeepTogether([table, Spacer(1, 14)]))
            else:
                story.extend([table, Spacer(1, 14)])
        # Each compact model-parameter block should stay with its own table,
        # preventing a page that begins with unexplained table continuation.
        if block["title"].startswith("参数 -"):
            group = story[section_start:]
            del story[section_start:]
            story.append(KeepTogether(group))
        if block["title"].startswith("2.") and (folder / "contact-sheet.png").exists():
            story.extend(figure(folder / "contact-sheet.png", "11张输入的派生缩略图；完整原始字节独立归档。"))
        if block["title"].startswith("5."):
            # Put the related scientific figures on a dedicated page so the
            # validation plot is not orphaned by the preceding pose table.
            story.extend([PageBreak(), Paragraph("角点覆盖与逐图留出验证", heading)])
            for name in ("coverage.png", "loo-errors.png"):
                if (folder / name).exists():
                    story.extend(figure(folder / name, "原始角点覆盖" if name == "coverage.png" else "逐图留出验证误差"))
        if block["title"].startswith("6."):
            for record in result["inputs"]:
                path = folder / f"comparison-{record['ordinal']:02}.jpg"
                if record["accepted"] and path.exists():
                    story.extend(figure(path, record["name"] + "：左原图 / 中鱼眼PC参考 / 右针孔PC参考（同一输出相机）"))
    story.extend([Paragraph("9. 算法资料", heading)])
    for label, url in SOURCES:
        story.append(Paragraph(escape(label) + "<br/>" + f"<link href='{url}'>{escape(url)}</link>", small))

    def footer(canvas, document):
        """Keep page identity separate from floating content and tables."""
        canvas.setFont(font, 8)
        canvas.setFillColor(colors.HexColor("#62788a"))
        canvas.drawString(42, 24, "RGB独立标定 / 候选参数 / 硬件未应用")
        canvas.drawRightString(A4[0] - 42, 24, str(document.page))
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
