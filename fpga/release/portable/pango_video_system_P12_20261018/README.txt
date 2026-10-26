Pango PG2L100H P12 portable design handoff, 2026-10-18

Read HANDOFF.md first. No qualified full-system bitstream is included.

From this package root:
  python fpga/scripts/portable_video_build.py --mode verify
  python fpga/scripts/portable_video_build.py --mode route-map --pds-home "C:/Pango/PDS_2022.2-SP6.4" --license-file "C:/Licenses/pango.lic"

Replace tool/licence paths with this PC settings. PDS build 146967 and Python 3.11+ required.
Other modes: prepare, compile, map, full, route-placement.
Every invocation creates fpga/build/<timestamp>.
Only successful fresh routed min/max timing permits bitgen. No programming is performed.
Historical .pds/Tcl/logs are evidence; use this driver to regenerate local paths.
