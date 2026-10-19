"""Prepare a two-clock board candidate and narrow CDC bounds; never run PnR."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,shutil

def once(text,old,new):
    if text.count(old)!=1:raise ValueError('Unexpected board anchor: '+old)
    return text.replace(old,new)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--model-input',type=Path,required=True)
    args=parser.parse_args();f=Path(__file__).resolve().parents[1];base=args.model_input.resolve()
    hashes=json.loads((base/'sources.json').read_text())
    assert all(hashlib.sha256((base/'source'/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
    assert json.loads((base/'candidate.json').read_text())['tile_refill_proof']
    run=f/'build/route_optimization'/datetime.now().strftime('proc150_board_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source');source=run/'source'
    shutil.copyfile(f/'experiments/proc150/rtl/processing_domain_reset.sv',source/'rtl/board/processing_domain_reset.sv')
    # Existing generated project IP, already tracked in this repository. No
    # installed vendor simulation libraries or encryption keys are copied.
    shutil.copytree(f/'ip/sys_pll',source/'ip/sys_pll')
    board=source/'rtl/board/pango_video_system.sv';text=board.read_text(encoding='utf-8')
    text=once(text,' wire ref_clk,ddr_clk,ddr_lock,ddr_ready;',
        ' wire ref_clk,ddr_clk,ddr_lock,ddr_ready;\n wire processing_raw_clk,processing_clk,processing_lock,processing_reset_n;')
    start=text.index(' reg fault_latched,memory_armed;');end=text.index(' GTP_INBUFDS',start)
    text=text[:start]+''' // Native initialization is independent of processing PLL startup. After
 // arming, controller and all ownership clients share immediate cold reset.
 wire fault_latched,memory_armed,joint_reset_n,fabric_async_reset_n;
 processing_domain_reset processing_safety(.control_clk(clk_27m),.external_reset_n(reset_n),
  .video_lock(video_lock),.processing_lock(processing_lock),.memory_lock(ddr_lock),.memory_ready(ddr_ready),
  .business_fault(core_fault),.camera_lost(camera_lost),.joint_reset_n(joint_reset_n),
  .fabric_async_reset_n(fabric_async_reset_n),.fault_latched(fault_latched),.memory_armed(memory_armed));
'''+text[end:]
    anchor=' video_pll u_video_pll('
    text=once(text,anchor,''' // Existing MINI reference is 125MHz (native DDR ref constraint). OUT1
 // is 125*6/5=150MHz; NOBUF output is promoted onto a real global network.
 sys_pll u_processing_pll(.clkin1(ref_clk),.clkout0(),.clkout1(processing_raw_clk),.clkout2(),.lock(processing_lock));
 GTP_CLKBUFG u_processing_global(.CLKIN(processing_raw_clk),.CLKOUT(processing_clk));
'''+anchor)
    text=once(text,' wire fabric_async_reset_n=joint_reset_n && ddr_lock && ddr_ready;',
        ' reset_sync rs_processing(processing_clk,fabric_async_reset_n,processing_reset_n);')
    start=text.index(' (* syn_preserve=1 *) reg fault_meta,fault_sync;');end=text.index(' dvp_clock_watchdog watchdog',start)
    text=text[:start]+' // Fault synchronization and sticky cold-reset arming live in processing_safety.\n'+text[end:]
    anchor='.clk(ddr_clk),.rst_n(core_reset_n),.controller_ready('
    text=once(text,anchor,'.clk(ddr_clk),.rst_n(core_reset_n),.processing_clk(processing_clk),.processing_rst_n(processing_reset_n),.controller_ready(')
    board.write_text(text,encoding='utf-8',newline='\n')
    clocks=source/'constraints/video_system/clocks_cdc.fdc';text=clocks.read_text(encoding='utf-8')
    # Preserve all original DDR, HDMI and board I/O constraints. Rename only
    # moved reset/health synchronizer endpoints, retaining stage-two timing.
    text=text.replace('{fault_meta}','{processing_safety.fault_meta}')
    text=text.replace('{memory_ready_meta}','{processing_safety.health_meta}')
    text=text.replace('{fault_latched memory_armed I_ips_ddr_top.',
        '{processing_safety.fault_latched processing_safety.memory_armed I_ips_ddr_top.')
    text=text.replace('{rs_core.stages* rs_camera.stages*',
        '{rs_processing.stages* rs_core.stages* rs_camera.stages*')
    text+='''
# sys_pll OUT1 uses the existing 125MHz differential reference. The global
# buffer inherits its exact waveform; no clock domain is broadly false-pathed.
create_generated_clock -name processing_pll_clk -source [get_ports ref_clk_p] -multiply_by 6 -divide_by 5 [get_pins {u_processing_pll.u_gpll/CLKOUT1}]
create_generated_clock -name processing_clk -source [get_pins {u_processing_pll.u_gpll/CLKOUT1}] -divide_by 1 [get_pins {u_processing_global/CLKOUT}]
'''
    clocks.write_text(text,encoding='utf-8',newline='\n')
    lines=['# Installed UCE guide printed p83: max-delay endpoints may be clocks.',
        '# The ONLY clock-target exception starts at named, immutable DDR job',
        '# fields. Timing paths stop at their first processing capture. All',
        '# processing-register -> processing-register paths remain ordinary.',
        '# Source ownership is held until the synchronized job completion.']
    job_sources='core.scheduler.geometry_source_base* core.scheduler.geometry_source_gen* core.scheduler.geometry_result_base* core.scheduler.geometry_result_gen* core.scheduler.geometry_saved* core.source_geometry*'
    lines += [f'set_max_delay 6.0 -datapath_only -from [get_cells -hierarchical {{{job_sources}}}] -to [get_clocks processing_clk]',
        f'set_false_path -hold -from [get_cells -hierarchical {{{job_sources}}}] -to [get_clocks processing_clk]']
    # Each remaining pair names a held bus/first-stage synchronizer. No second
    # stage or downstream processing data path is included in these exceptions.
    pairs=[('core.processor.job_mailbox.request_toggle','core.processor.job_mailbox.request_meta'),
        ('core.processor.job_mailbox.free_toggle','core.processor.job_mailbox.free_meta'),
        ('core.processor.job_mailbox.response_toggle','core.processor.job_mailbox.response_meta'),
        ('core.processor.job_mailbox.failed_held','core.processor.job_mailbox.source_failed'),
        ('core.processor.refill_bridge.request_toggle','core.processor.refill_bridge.request_meta'),
        ('core.processor.refill_bridge.tile_held*','core.processor.refill_bridge.memory_tile_*'),
        ('core.processor.refill_bridge.quads.write_gray*','core.processor.refill_bridge.quads.write_meta*'),
        ('core.processor.refill_bridge.quads.read_gray*','core.processor.refill_bridge.quads.read_meta*'),
        ('core.processor.result_bridge.request_toggle','core.processor.result_bridge.request_meta'),
        ('core.processor.result_bridge.free_toggle','core.processor.result_bridge.free_meta'),
        ('core.processor.result_bridge.cancel_held','core.processor.result_bridge.cancel_meta'),
        ('core.processor.result_bridge.response_toggle','core.processor.result_bridge.response_meta'),
        ('core.processor.result_bridge.descriptor_held*','core.processor.result_bridge.memory_req_*'),
        ('core.processor.result_bridge.status_held*','core.processor.result_bridge.done_tag* core.processor.result_bridge.error core.processor.result_bridge.cancelled'),
        ('core.tone_cursor* core.tone_commit','core.tone_ready_meta')]
    for start,end in pairs:
        lines += [f'set_max_delay 6.0 -datapath_only -from [get_cells -hierarchical {{{start}}}] -to [get_cells -hierarchical {{{end}}}]',
            f'set_false_path -hold -from [get_cells -hierarchical {{{start}}}] -to [get_cells -hierarchical {{{end}}}]']
    (source/'constraints/video_system/processing_cdc.fdc').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    hashes={p.relative_to(source).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob('*') if p.is_file()}
    (run/'sources.json').write_text(json.dumps(hashes,indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(status='BOARD_COMPILE_MAP_AND_CDC_AUDIT_REQUIRED',
        production_instantiated=False,model_input=str(base),whole_design_route_allowed=False,
        processing_clock_target_mhz=150,ddr_clock_mhz=125,official_ddr_ip_modified=False,
        cdc_bounds_ns=6,clock_group_false_paths=False,installed_uce_reference='User_Constraint_Editor_User_Guide.pdf printed p83'),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print('PROC150_BOARD_CANDIDATE',run)

if __name__=='__main__':main()
