# FPGA display control and marker integration

Implementation scope: `raw8_geometry_core.v`, `mcu_protocol.v`,
`mini_raw8_geometry.v`, and new `geometry_marker*.v` / `geometry_view*.v`.
Existing dirty optimization changes were retained. No commit, push, PDS run,
vendor/reference change or hardware programming was performed by this work.

## Interface and frame ownership

The processor takes `display_original` and exposes `active_words_out[447:0]`,
`active_model_out[1:0]`, `active_enhance_out`. `frame_original` may be left open.
On source `h_grant`, view intent is frozen and `geo_start` is asserted. The
processor samples that stable intent on the following edge. Marker start is
delayed one further edge so it consumes newly activated config-bank words.
The processor's original view therefore retains its same ISP and active K/D.

Result publication waits for both the existing DDR fence and marker-table
completion. Each of three result slots owns coordinates, visibility, control
revision, packed control, parameter version and calculation status. No marker
coordinates come from the host.

On an HDMI lease, the memory domain holds the entire 1428-bit metadata bus.
`request_toggle -> req_meta/req_sync` transfers ownership; the pixel domain
samples the held bus and returns `pixel_ack_toggle -> ack_meta/ack_sync`.
Only then may core acknowledge the image lease. After the consumer drops its
request and the frame acknowledgment returns low, the next vertical boundary
activates the overlay. The first active raster returns `display_toggle`.
Memory readback then snapshots the still-leased bus. CDC physical constraints
and STA remain the parent's final integration responsibility; this is not an
independently synchronized multi-bit bus. Lease lifetime is part of the contract.

Generation increments only for the first displayed metadata or a change in the
entire displayed metadata bus. The equality is registered before the displayed
token returns. Identical repeated video frames do not invalidate a slow UART
table sweep. Generation is a metadata revision, never an HDMI source frame ID.
The host must read generation before and after its sweep and retry on change;
external HDMI frame ID remains `null/unverified`.

## UART protocol

`DISPLAY_CONTROL` is independently optional, default 0; the geometry board sets
it to 1. CAPS preserves `0x80` and adds `0x100` only when enabled.

`0x35` has 24 bytes: epoch/session prefix (12), requested revision LE32,
flags LE32, marker size LE32. Bit 0 selects original, bit 1 enables markers;
all other flag bits are rejected. Size is 4..32, nominal default 10. Defaults
are corrected and markers disabled. Revisions must be nonzero and increase
within the session; identical retries return DUPLICATE, conflicting reuse
returns ID_CONFLICT. A session/epoch change clears pending intent to defaults.
The 12-byte extension reply is requested revision, actually displayed revision,
actually displayed flags OR size shifted by 8. A successful request only stages
intent; it does not claim application.

READ `0x34`, bank 2:

| Index | Value |
| --- | --- |
| 0 | `0x4d4b5231` |
| 1 | Displayed control revision |
| 2 | Displayed flags OR size shifted by 8 |
| 3 | Displayed parameter version |
| 4 | Geometric visible mask, twenty low bits; independent of overlay enable |
| 5 | Displayed metadata generation |
| 6 | Calculation status: bit0 complete, bit1 mapping failure, bit2 LUT build failure, bit3 unsupported model |
| 16+5*i | Canonical source x low16 / y high16, i=0..19 |
| +1,+2 | Signed destination x/y Q12; `0x80000000` means no valid solution |
| +3 | Canonical RGB24 |
| +4 | Bit0 geometrically visible |

Supported forward models: bypass, equidistant fisheye and radial Brown with
zero tangential coefficients. Forward calculation reverses the same quantized,
FPGA-built radial LUT and then the 2x2 affine transform. Tangential Brown,
singular transforms, unrepresentable normalization and LUT-domain overflow fail
explicitly. Valid offscreen coordinates remain signed and unclamped with the
visibility bit clear. Twenty points use one shared pipelined multiplier plus
iterative root/division; this block is not a pixel-throughput engine.

## Image boundary and evidence

The final overlay draws canonical colors, compact numbered labels and black
outlines. RGB, HS, VS and DE all delay exactly two pixel clocks. Any full-core
scoreboard must delay its expected raster/sample reference equally and retain
its pixel checks. The overlay has no memory/network write path. Network output
retains existing `ENHANCE(1)`, RENH descriptor and version 2; it has not been
relabeled as raw S0. Source-byte invariance is verified at the overlay input /
output boundary; full source/network traffic checks remain board-core tests.

Run `fpga/scripts/sim_geometry_markers.ps1` with ModelSim SE 10.1c. Its independent
golden generator imports the actual `host/web/fisheye-preview.js` marker API.
Tests cover all twenty coordinates/colors, original/bypass exactness, default
fisheye analytic agreement and crop mask, Brown identity, affine reflection,
singular and unsupported cases, async slot/version switching, stable generation
across repeated frames and a complete 100-word metadata sweep, overlay pixel /
outline / digit alignment and untouched input samples, and physical UART framing,
CRC, exact length, session/epoch checks, duplicate/conflict behavior and capability
enabled/disabled cases. Logs are generated under `fpga/build/geometry_markers_*`.

The reviewed default's sixteen visible markers differed from the analytic JS
reference by at most 32 Q12 units (0.0078125 pixel) on either axis in the observed
run; the regression allows 0.5 pixel for the existing radial LUT approximation.
The four corners are cropped. These are simulation results, not board accuracy,
frame-rate, power, UVC pairing, synthesis or routed timing acceptance.

Final local regression: `fpga/build/geometry_markers_20261006_202255_686`.
`GEOMETRY_MARKERS_PASS`, `GEOMETRY_VIEW_PASS`, and
`GEOMETRY_VIEW_UART_PASS` with DISPLAY=1 (11 replies) and DISPLAY=0 (3 replies)
all passed. The final run includes the full repeated-frame metadata sweep and
exact center/outline/digit alignment assertions. `git diff --check` passed for
the three edited existing RTL files. Parent owns full board-core regression,
PDS synthesis, placement/routing and STA; its CDC constraints retain the stated
register names.
