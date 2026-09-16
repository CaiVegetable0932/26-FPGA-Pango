"""Generate a non-release routing diagnostic; never used by the main build."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
dest = root / "build/route_isolation"
dest.mkdir(exist_ok=True)
top = (root / "rtl/board/pango_video_top.v").read_text(encoding="utf-8")
start = top.index("    tmds_serializer u_hdmi_clock")
end = top.index("    (* syn_preserve", start)
top = top[:start] + """    // DIAGNOSTIC ONLY: isolate serializer routing, never generate a bitstream.
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_clk (.I(pixel_clk), .O(hdmi_clk_p), .OB(hdmi_clk_n));
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_d0 (.I(pixel_clk), .O(hdmi_data_p[0]), .OB(hdmi_data_n[0]));
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_d1 (.I(pixel_clk), .O(hdmi_data_p[1]), .OB(hdmi_data_n[1]));
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) diag_d2 (.I(pixel_clk), .O(hdmi_data_p[2]), .OB(hdmi_data_n[2]));
""" + top[end:]
(dest / "pango_video_top.v").write_text(top, encoding="utf-8")
recipe = (root / "project/pango_video_top/pango_video_top.tcl").read_text(encoding="utf-8")
recipe = recipe.replace("[file normalize [file join [file dirname [info script]] ../..]]", "{" + root.as_posix() + "}")
recipe = recipe.replace("set_dir -impl_directory [file join $fpga_root build pango_video_top]", "set_dir -impl_directory {" + dest.as_posix() + "}")
recipe = recipe.replace("[file join $fpga_root rtl board pango_video_top.v]", "{" + (dest / "pango_video_top.v").as_posix() + "}")
recipe = recipe[:recipe.index("report_timing")]
(dest / "isolate_hdmi.tcl").write_text(recipe, encoding="utf-8")
print(dest / "isolate_hdmi.tcl")
