"""Restore the agreed implementation directory after native PDS saves it as '.' ."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
project = root / "project/pango_video_top/pango_video_top.pds"
data = project.read_text(encoding="utf-8")
old = '(_option prj_impl_dir (_string "."))'
new = '(_option prj_impl_dir (_string "../../build/pango_video_top"))'
if data.count(old) == 1:
    project.write_text(data.replace(old, new), encoding="utf-8")
elif data.count(new) != 1:
    raise RuntimeError("Unexpected native project implementation-directory syntax")
print("Project implementation directory: fpga/build/pango_video_top")
