"""Fail-closed offline release gate for the full RAW8 board, not hardware proof."""
import argparse
import json
from pathlib import Path
import re
from audit_comms_candidate import sha, source_path


def read_native_text(path):
    """Decode PDS/simulation evidence from PowerShell 5.1 or modern shells."""
    # Purpose: Tee-Object writes both logs and redirected JSON as UTF-16 LE
    # on Windows PowerShell 5.1; modern shells may use UTF-8. Keep strict
    # decoding so evidence corruption still fails the release audit.
    with path.open('rb') as stream:
        signature = stream.read(2)
    encoding = 'utf-16' if signature in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig'
    return path.read_text(encoding=encoding)


def audit(run, simulation, clock_simulation, bridge_simulation):
    """Require fresh routed image, unchanged inputs and full-core host interop."""
    root = Path(__file__).resolve().parents[1]
    impl = root / 'build/mini_raw8_dual/implementation'
    # Audit the final native report, not just an archival copy. The builder
    # exports the exact routed DB and verifies it is unchanged during export.
    report = impl / 'report_timing/mini_raw8_dual.rtr'
    image = run / 'mini_raw8_dual.sbit'
    result = json.loads(read_native_text(run / 'result.json'))
    if not all(result.get(k) for k in ('native_stage_completed', 'timing_constraints_met', 'bitstream_generated')):
        raise ValueError('native board flow incomplete')
    for log in ('report_timing.log', 'gen_bit_stream.log'):
        if re.search(r'(?m)^E:|STA-301[35]|not found in current design', read_native_text(run / log)):
            raise ValueError('native constraint/flow diagnostic in ' + log)
    text = read_native_text(report)
    if not re.search(r'^Design Summary\s*:\s*All Constraints Met\.', text, re.M) or 'Slack (VIOLATED)' in text:
        raise ValueError('routed timing failed')
    for token in ('PG2L100H', 'FBG676', 'Speed Grade  : -6'):
        if token not in text:
            raise ValueError('wrong target')
    for clock, period in (('ddrphy_sysclk', '8.0000'), ('ETH125', '8.0000'), ('PHY_SAMPLE', '8.0000'),
                          ('camera_pclk_budget', '10.0000'), ('pixel_clk', '13.4680')):
        if not re.search(r'\b' + clock + r'\s+' + re.escape(period) + r'\s+\{', text):
            raise ValueError('clock missing/wrong: ' + clock)
    if not re.search(r'PHY_SAMPLE\s+8\.0000\s+\{2\.0000 6\.0000\}', text):
        raise ValueError('PHY delay policy differs')
    # Both corners must still analyze all five DDR data/control endpoints for
    # setup AND hold. A clock declaration that accidentally cuts these paths
    # must never become an apparent all-constraints-met release.
    rgmii_checks = re.findall(r'^\s*ETH125\s+PHY_SAMPLE\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s*$', text, re.M)
    if len(rgmii_checks) != 4 or any(float(s) < 0 or int(f) != 0 or int(n) != 5
                                   for s, total, f, n in rgmii_checks):
        raise ValueError('RGMII setup/hold endpoint coverage lost')
    for corner in ('Slow', 'Fast'):
        for check in ('Setup', 'Hold', 'Recovery', 'Removal', 'Minimum Pulse Width'):
            if f'{check} Summary({corner} Corner)' not in text:
                raise ValueError('missing timing coverage')
    manifest = json.loads(read_native_text(run / 'source_manifest.json'))
    for item in manifest:
        if sha(source_path(root, item['path'])).lower() != item['sha256'].lower():
            raise ValueError('build source changed: ' + item['path'])
    if image.stat().st_size < 10000 or image.stat().st_mtime < report.stat().st_mtime:
        raise ValueError('image missing/stale')
    if sha(image) != sha(impl / 'generate_bitstream/mini_raw8_dual.sbit'):
        raise ValueError('image differs from final native output')
    sim = json.loads(read_native_text(simulation / 'result.json'))
    if not (sim.get('passed') and sim.get('frames') == 6 and sim.get('host_reassembly_verified') and sim.get('native_fifo_models_verified') and sim.get('gmii_packet_cdc_verified')):
        raise ValueError('six-frame native core/host regression required')
    for item in json.loads(read_native_text(simulation / 'sources.json')):
        if sha(source_path(root, item['path'])).lower() != item['sha256'].lower():
            raise ValueError('simulation source changed: ' + item['path'])
    late = json.loads(read_native_text(simulation / 'late_epoch_result.json'))
    if not (late.get('passed') and late.get('frames') == 5 and late.get('first_frame_id') == 1):
        raise ValueError('precommissioned frame exclusion not verified')
    # The board uses a free-running forwarding ODDR. Require its exact native
    # model reset/byte regression, independently of the core's GMII scoreboard.
    clock_sim = json.loads(read_native_text(clock_simulation / 'result.json'))
    if not (clock_sim.get('passed') and clock_sim.get('native_gtp_models') and
            clock_sim.get('vectors') == 1024 and clock_sim.get('local_resets') == 4):
        raise ValueError('native forwarding clock regression missing')
    for item in clock_sim['sources']:
        if '/fpga/' in item['path'].replace('\\', '/'):
            if sha(source_path(root, item['path'])).lower() != item['sha256'].lower():
                raise ValueError('clock simulation source changed')
    # Faster/slower consumer clocks plus partial-frame error and two-sided
    # reset recovery complement full-image payload validation after the bridge.
    bridge_sim = json.loads(read_native_text(bridge_simulation / 'result.json'))
    if not (bridge_sim.get('passed') and bridge_sim.get('packets_per_case') == 81 and
            bridge_sim.get('read_half_period_ns') == [3.9, 4.1] and bridge_sim.get('native_fifo_models')):
        raise ValueError('native packet clock bridge regression missing')
    for item in bridge_sim['sources']:
        if sha(source_path(root, item['path'])).lower() != item['sha256'].lower():
            raise ValueError('packet bridge simulation source changed')
    return dict(timing_constraints_met=True, checked_inputs=len(manifest),
        bitstream=str(image), bitstream_sha256=sha(image), timing_report=str(report),
        timing_sha256=sha(report), simulation=str(simulation), simulation_result=sim,
        clock_simulation=str(clock_simulation), clock_simulation_result=clock_sim,
        bridge_simulation=str(bridge_simulation), bridge_simulation_result=bridge_sim,
        # Purpose: report the actual processing stage at both outputs; the
        # Ethernet payload is still Bayer RAW8 but no longer untouched S0.
        image_kind='1080p RAW8 DVP -> DDR -> FPGA-enhanced PRAW Bayer RAW8 + enhanced HDMI grayscale candidate',
        programmed=False, hardware_tested=False, external_dvp_timing_verified=False,
        external_hdmi_eye_verified=False, rgmii_pcb_skew_measured=False,
        hdmi_source_frame_id=None, physical_camera_source_verified=False,
        qualification='First-board candidate; not continuous1080p30/ISP/correction acceptance')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('simulation', type=Path)
    parser.add_argument('clock_simulation', type=Path)
    parser.add_argument('bridge_simulation', type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.run.resolve(), args.simulation.resolve(), args.clock_simulation.resolve(), args.bridge_simulation.resolve()), indent=2))
