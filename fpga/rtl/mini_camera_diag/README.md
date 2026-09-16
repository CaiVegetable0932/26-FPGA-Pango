# MINI CAM1 diagnostic (not released for programming)

This isolated project adapts the board vendor's **PG2L200H/FBB676 dual-OV5640
demo** to **PG2L100H-6FBG676**, using PDS 2022.2-SP6.4 build 146967.
It is not the production RAW8/1080p30 pipeline.

## Scope

- J10 / CAM1 (`camera_0`) only, using the reviewed official DOUBLE_DVP_OV5640 module pinout.
- Vendor 1280×720 RGB565 register sequence, with SCCB open-drain drive,
  ACK/NACK/timeout handling and no writes to read-only chip-ID registers.
- Single full-width capture/display path; no dual-camera downscaling or compositor.
- Native 100H DDR controller and video PLL reused from this project's IP directory.
- Native FIFO names are historical: actual widths are **16→256** and **256→16**.
- Four 2 MiB DDR slots, 57,600 32-byte words per 720p frame.
- 74.25 MHz / 371.25 MHz coherent HDMI pixel/serial clocks.
- No Ethernet, UDP/PRAW, FPGA ISP, geometric correction, or PC-host integration.

## Source preservation

Original source:
`reference/盘古100K200K MINI开发板/2_Demo/5_1 双目摄像头例程/ov5640_200k`.

The original tree is read-only. Source SHA256/import mapping is recorded in
`fpga/build/mini_camera_diag/source_import_manifest.json`.
Only this imported copy and its copied native FIFO IPs were adapted.
Four imported text files were normalized from GBK to UTF-8 in the copy:
`sync_vg.v`, `iic_dri.v`, `rgb2tmds.v`, `tmds_encoder.v`.

Unused vendor scaler and MS72xx HDMI bridge controllers are retained for provenance,
but are **not** included in this project. The board's native TMDS path is used.

## Entry points

- Project: `fpga/project/mini_camera_diag/mini_camera_diag.pds`.
- Native project specification: same directory, `mini_camera_diag.tcl`.
- Offline tests: `fpga/scripts/sim_mini_camera_diag.ps1`.
- Native generation/build: `fpga/scripts/build_mini_camera_diag.ps1`
  (`-GenerateIps`, `-Stage compile|synthesize|dev_map|pnr|report_timing`).
- Build evidence: `fpga/build/mini_camera_diag/`.

The build script does not invoke JTAG and exposes no bitstream or programming step.
The optional license path is used only in the child process environment and is never
read, copied into evidence, or persisted as a system setting.

## Remaining release blockers

1. Recorded prior `over_temp=1` has not been cleared by measured evidence.
   The flag is not itself an ADC temperature reading.
2. DVP mode-specific input setup/hold and board/cable skew, HDMI output timing,
   and final CDC/serializer placement constraints remain unverified.
   The 100 MHz camera clock is a **provisional analysis budget**, not measured PCLK.
3. Vendor frame-index rotation is not a write-completed, read-owned frame pool.
   Initial reads can reference unwritten memory; no complete-frame/tear-free claim.
4. Short/oversized frames, FIFO overflow/underflow, DMA stalls and frame invalidation
   still require implementation/regression. Byte re-alignment is not frame validation.
5. SCCB ACK completion is not a sensor-ID or register-readback check.
6. Native compilation/synthesis, or a produced timing report, does not constitute
   camera/DDR/video functionality, external timing closure or hardware verification.

See `fpga/reports/mini_camera_diag_20260914.md` for actual executed results.
