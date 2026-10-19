"""Run integration RTL from frozen source copies; never program hardware."""
from pathlib import Path
from datetime import datetime
import hashlib
import json
import subprocess
import argparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-snapshot', type=Path, help='Read immutable source directory from a board build')
    parser.add_argument('--cases', nargs='+')
    parser.add_argument('--control-test', action='store_true')
    parser.add_argument('--snapshot-test', action='store_true')
    parser.add_argument('--network-test', action='store_true', help='Exercise link loss/recovery in integrated core')
    parser.add_argument('--board-client-limits', action='store_true',
                        help='Exercise board-specific 3/3/2/1/1 transaction capacities in standalone fixtures')
    parser.add_argument('--full-frame', action='store_true', help='Run native video core at 1920x1080')
    parser.add_argument('--acquire-wait-cycles',type=int,default=0,
                        help='Bounded legal ACQUIRE wait in ownership fixtures (0 preserves immediate baseline)')
    options = parser.parse_args()
    if not 0<=options.acquire_wait_cycles<=8:
        parser.error('acquire wait must be bounded within 0..8 cycles')
    # The link-loss fixture intentionally retains display offers; the control
    # fixture releases them itself. Their frame identities/consumer schedules
    # are separate scenarios, not composable flags on the same SV stimulus.
    if options.network_test and options.control_test:
        parser.error('run link-loss and parameter-control scenarios separately')
    # Freeze exactly the tested RTL and retain every compile/runtime failure.
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('sim_%Y%m%d_%H%M%S_%f')
    snapshot = run / 'source'
    snapshot.mkdir(parents=True)
    names = ['rtl/memory/frame_manager_pkg.sv', 'rtl/memory/frame_manager_layout.vh',
             'rtl/memory/snapshot_copy_dma.sv','rtl/memory/frame_snapshot_pair.sv','rtl/control/video_snapshot_service.sv','rtl/memory/frame_pool_bank.sv', 'rtl/memory/frame_manager.sv',
             'rtl/memory/ddr_native_dma.v', 'rtl/memory/frame_memory_fabric.sv',
             'rtl/memory/geometry_tile_refill.sv', 'sim/tb_geometry_tile_refill.sv',
             'sim/tb_frame_memory_fabric.sv', 'sim/tb_ddr_native_dma.sv',
             'rtl/input/ov5640_raw8_mode.v', 'rtl/input/ov5640_register_service.v',
             'rtl/mini_camera_diag/vendor/camera/SCCB.v', 'sim/ov5640_sccb_model.sv',
             'sim/tb_ov5640_raw8_mode.sv', 'sim/tb_geometry_native_integration.sv',
             'rtl/memory/frame_pixel_writer.sv', 'rtl/memory/dma_pixel_pack.v', 'sim/tb_frame_pixel_writer.sv',
             'rtl/geometry/geometry_frame_processor.sv', 'sim/tb_geometry_frame_processor.sv',
             'rtl/memory/dma_read_cdc.sv', 'sim/tb_dma_read_cdc.sv']
    names += ['rtl/input/ov5640_integrated_startup.v', 'rtl/input/ov5640_reference_profile.v',
              'rtl/mini_camera_diag/vendor/camera/data_init.v', 'sim/tb_ov5640_integrated_startup.sv']
    names += ['rtl/geometry/' + name for name in [
        'unsigned_mult32_pipe.sv','signed_mult40_unsigned40_pipe.sv','legacy_tone_lut.v', 'projective_ray_stepper.sv', 'perspective_divide.sv', 'affine_ray_stepper.sv', 'lens_inverse_map.sv', 'signed_mult32_pipe.sv',
        'rgb_tile_cache.sv', 'rgb_cache_bank.sv', 'rgb_bilinear.sv',
        'gamma_lut_bank.sv', 'rgb_enhance.sv', 'geometry_rgb_pipeline.sv']]
    # Board integration uses the real ISP, scheduler and network dependencies.
    names += ['rtl/memory/frame_writer_buffer.sv', 'rtl/memory/async_stream_fifo.sv', 'rtl/input/camera_frame_cdc.sv',
              'rtl/input/dvp_frame_receiver.v', 'rtl/input/dvp_raw8_fanout.v',
              'rtl/control/video_frame_scheduler.sv', 'rtl/board/video_memory_core.sv',
              'rtl/isp/raw8_isp.sv', 'rtl/isp/isp_line_store.sv', 'rtl/isp/rgb_colour_matrix.sv', 'rtl/isp/rgb_frame_statistics.sv', 'rtl/control/parameter_entity_guard.sv','rtl/control/frame_parameter_bank.sv',
              'rtl/memory/dma_byte_unpack.v', 'sim/tb_camera_frame_cdc.sv',
              'sim/tb_video_memory_core.sv']
    # Include the actual five-bank snapshot ownership fixture when checking a
    # frozen control-path candidate; no regenerated/live RTL enters the run.
    names += ['sim/tb_frame_snapshot_pair.sv', 'sim/video_core_display_fixture.sv']
    names += ['sim/tb_frame_manager_pressure.sv','sim/tb_frame_metadata_read.sv']
    names += ['rtl/network/' + p.name for p in sorted((fpga / 'rtl/network').glob('*.sv'))]
    names += ['rtl/control/uart_8n1.sv', 'rtl/control/uart_v2_parser.sv', 'rtl/control/pc_video_boot.sv',
              'rtl/video/display_frame_cdc.sv', 'sim/tb_pc_runtime_control.sv', 'sim/tb_pc_video_boot.sv', 'sim/tb_board_service_cdc.sv', 'sim/tb_perspective_domain.sv','sim/tb_wide_multipliers.sv','sim/tb_projective_ray_stepper.sv', 'sim/tb_frame_ticket_rollover.sv']
    hashes = {}
    for name in names:
        # Select the actual immutable bitstream-build RTL, retaining live test
        # fixtures only. No source copy or generated IP is edited in place.
        origin = (options.rtl_snapshot / name) if options.rtl_snapshot and name.startswith('rtl/') else (fpga / name)
        data = origin.read_bytes()
        # Exercise the capacity specialization in standalone fabric/ownership
        # fixtures as well as the real board core. Preserve independent drain
        # and byte scoreboards; the oversubscribed seven-client scenario must
        # release its readback gate while excess producers are backpressured.
        if options.board_client_limits:
            substitutions = {
                'sim/tb_frame_memory_fabric.sv': ('frame_memory_fabric dut(.*);',
                    'frame_memory_fabric #(.BOARD_CLIENT_LIMITS(1)) dut(.*);'),
                'sim/tb_frame_snapshot_pair.sv': ('frame_manager dut(clk,reset_n,fabric_ready,display_boundary,command_bus,response_bus);',
                    'frame_manager #(.BOARD_CLIENT_LIMITS(1)) dut(clk,reset_n,fabric_ready,display_boundary,command_bus,response_bus);'),
                'sim/tb_frame_manager_pressure.sv': ("frame_pool_bank pool(clk,reset_n,fabric_ready,1'b0,command,response);",
                    "frame_pool_bank #(.TXNS(3)) pool(clk,reset_n,fabric_ready,1'b0,command,response);")}
            if name in substitutions:
                old, new = substitutions[name]
                text = data.decode('utf-8')
                if text.count(old) != 1:
                    raise ValueError('Unexpected board capacity fixture: '+name)
                data = text.replace(old, new, 1).encode('utf-8')
            if name == 'sim/tb_frame_memory_fabric.sv':
                text = data.decode('utf-8').replace('\r\n', '\n')
                old = '''   begin request(6,1,1536,2,0);payload(6,2);end
  join
  seal;repeat(10)tick;response=frame_response[0+:RSP_BITS];
  check(response.published==0,"seven writes retain publication fence");
  block_read=0;wait(done==7'h7f);repeat(3)tick;response=frame_response[0+:RSP_BITS];
  check(error==0 && !fault && response.published==1,"seven unique completions publish exactly once");'''
                new = '''   begin request(6,1,1536,2,0);payload(6,2);end
   begin
    // Seven synthetic writers deliberately exceed the board's SRC bound.
    // Prove all three tokens fill and four clients wait; then permit drain
    // before waiting for all payloads, avoiding a test-created circular wait.
    repeat(100)tick;
    check(dut.frames.banks[0].pool.token_busy[0] &&
          dut.frames.banks[0].pool.token_busy[1] &&
          dut.frames.banks[0].pool.token_busy[2],"three token capacity filled");
    begin integer waiting_clients;waiting_clients=0;
     for(integer ci=0;ci<7;ci++)if(dut.state[ci]==1)waiting_clients++;
     check(waiting_clients==4 && done==0,"four excess writers backpressured before drain");
    end
    block_read=0;
   end
  join
  wait(done==7'h7f);repeat(3)tick;response=frame_response[0+:RSP_BITS];
  check(error==0 && !fault && response.published==0,"seven completions held until seal");
  seal;repeat(3)tick;response=frame_response[0+:RSP_BITS];
  check(response.published==1,"seven unique completions publish exactly once");'''
                if text.count(old) != 1:
                    raise ValueError('Unexpected oversubscribed fabric fixture')
                data = text.replace(old, new, 1).encode('utf-8')
        # Only the stimulus handshake is latency-aware. Existing payload,
        # ownership, error/drain and timeout assertions remain unchanged. Hash
        # the actual adapted fixture, so evidence cannot hide its wait bound.
        if options.acquire_wait_cycles and name=='sim/tb_frame_snapshot_pair.sv':
            text=data.decode('utf-8').replace('\r\n','\n')
            old=''' begin @(negedge clk); external_command[bank]=action; #1; observed=response[bank];
  tick; external_command[bank]='0; #1;'''
            new=''' integer acquire_wait;
 begin @(negedge clk); external_command[bank]=action; #1; observed=response[bank];
  // A legal command may wait for a synchronous descriptor; never skip ACK.
  acquire_wait=0;
  while(action.acquire!=0 && observed.acquire_ok!=action.acquire && acquire_wait<BOUND)begin
   tick;acquire_wait=acquire_wait+1;observed=response[bank];
  end
  if(action.acquire!=0)check(observed.acquire_ok==action.acquire,"bounded acquire ACK");
  tick; external_command[bank]='0; #1;'''.replace('BOUND',str(options.acquire_wait_cycles))
            if text.count(old)!=1:raise ValueError('Snapshot fixture changed; review latency adaptation')
            data=text.replace(old,new).encode('utf-8')
        if options.acquire_wait_cycles and name=='sim/tb_frame_memory_fabric.sv':
            text=data.decode('utf-8').replace('\r\n','\n')
            old='command=0;command.acquire=1;action(command);check(response.acquire_ok==1,"acquire immutable source");'
            new='''// This is the legal visibility case only; the earlier negative
  // acquisition keeps its immediate refusal check.
  command=0;command.acquire=1;
  @(negedge clk);frame_command[0+:CMD_BITS]=command;#1;response=frame_response[0+:RSP_BITS];
  begin integer acquire_wait;acquire_wait=0;
   while(!response.acquire_ok[PROCESS] && acquire_wait<BOUND)begin
    tick;acquire_wait=acquire_wait+1;response=frame_response[0+:RSP_BITS];
   end
  end
  tick;frame_command=0;check(response.acquire_ok==1,"acquire immutable source");'''.replace('BOUND',str(options.acquire_wait_cycles))
            if text.count(old)!=1:raise ValueError('Fabric fixture changed; review latency adaptation')
            data=text.replace(old,new).encode('utf-8')
        (snapshot / Path(name).name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    (run / 'sources.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    (run / 'simulation_script.py').write_bytes(Path(__file__).read_bytes())
    runtime = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    sources = [str(snapshot / Path(n).name) for n in names if not n.endswith('.vh')]
    result = {'passed': False, 'hardware_tested': False, 'board_integrated': False, 'full_frame_simulation': options.full_frame, 'rtl_snapshot': str(options.rtl_snapshot) if options.rtl_snapshot else None, 'snapshot_test': options.snapshot_test, 'control_test': options.control_test, 'tests': []}
    result['acquire_wait_cycles']=options.acquire_wait_cycles
    result['board_client_limits']=options.board_client_limits
    try:
        cases = ['tb_frame_manager_pressure','tb_frame_snapshot_pair','tb_perspective_domain','tb_wide_multipliers','tb_pc_runtime_control', 'tb_frame_ticket_rollover', 'tb_projective_ray_stepper', 'tb_pc_video_boot', 'tb_board_service_cdc', 'tb_camera_frame_cdc', 'tb_video_memory_core', 'tb_frame_memory_fabric', 'tb_frame_pixel_writer', 'tb_dma_read_cdc', 'tb_geometry_tile_refill', 'tb_geometry_native_integration',
                    'tb_geometry_frame_processor',
                    'tb_ddr_native_dma', 'tb_ov5640_raw8_mode', 'tb_ov5640_integrated_startup']
        if options.cases:
            # The speculative-read boundary fixture belongs to the synchronous
            # metadata candidate only; the live asynchronous baseline has no
            # intervening read edge and keeps its original default regression.
            unknown = set(options.cases) - (set(cases)|{'tb_frame_metadata_read'})
            if unknown:
                raise ValueError(f'Unknown cases: {sorted(unknown)}')
            cases = options.cases
        for top in cases:
            image = run / (top + '.vvp')
            compile_cmd = [str(runtime / 'iverilog.exe'), '-g2012', '-I', str(snapshot),
                           '-s', top, '-o', str(image), *sources]
            if options.snapshot_test and top == 'tb_video_memory_core':
                compile_cmd[1:1] = ['-Ptb_video_memory_core.SNAPSHOT_TEST=1']
            if options.control_test and top == 'tb_video_memory_core':
                compile_cmd[1:1] = ['-Ptb_video_memory_core.CONTROL_TEST=1']
            if options.network_test and top == 'tb_video_memory_core':
                compile_cmd[1:1] = ['-Ptb_video_memory_core.NETWORK_TEST=1']
            if options.full_frame and top == 'tb_video_memory_core':
                compile_cmd[1:1] = ['-Ptb_video_memory_core.WIDTH=1920', '-Ptb_video_memory_core.HEIGHT=1080']
            # Preserve the original tap-4 regression; exercise the recovered
            # MINI output-crop tap explicitly in this integration regression.
            if top == 'tb_ov5640_raw8_mode':
                compile_cmd[1:1] = ['-Ptb_ov5640_raw8_mode.RAW_OUTPUT_SELECT=3']
            for phase, command in [('compile', compile_cmd), ('run', [str(runtime / 'vvp.exe'), str(image)])]:
                completed = subprocess.run(command, cwd=run, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=1200 if options.full_frame else 180)
                (run / (top + '.' + phase + '.log')).write_bytes(completed.stdout)
                log = completed.stdout.decode(errors='replace')
                if completed.returncode or (phase == 'run' and ('_PASS' not in log or 'FATAL' in log)):
                    raise RuntimeError(f'{top} {phase}: {log[-4500:]}')
            result['tests'].append(top)
            print(top, 'PASS', flush=True)
        # These are test-fixture bytes, with an opaque identity token. They are
        # not sensor S1 evidence or a hardware-confirmed same-frame snapshot.
        images = sorted(run.glob('*.rgb'))
        if images:
            if {p.name for p in images} != {'s1_source.rgb', 'result_mode_0.rgb', 'result_mode_1.rgb', 'result_mode_2.rgb'}:
                raise RuntimeError('Synthetic RGB evidence set is incomplete')
            if any(p.stat().st_size != 35*33*3 for p in images):
                raise RuntimeError('Synthetic RGB evidence byte length mismatch')
            image_meta = {'width': 35, 'height': 33, 'format': 'RGB888', 'stored_stride': 105,
                          'ddr_stride': 6144, 'source': 'synthetic RTL memory formula',
                          'hardware_tested': False, 'opaque_metadata_hex': '8000000000000007',
                          'files': {p.name: {'bytes': p.stat().st_size,
                          'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in images}}
            (run / 'synthetic_rgb_metadata.json').write_text(json.dumps(image_meta, indent=2), encoding='utf-8')
        result['passed'] = True
    finally:
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('RUN', run, flush=True)


if __name__ == '__main__':
    main()
