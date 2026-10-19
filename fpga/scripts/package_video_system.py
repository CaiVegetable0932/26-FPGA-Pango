"""Package an actually routed/timed video bitstream with immutable evidence."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET
import zipfile


def digest(path):
    """Hash artifact bytes, including native stream and source manifests."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verified_geometry_budget(simulation):
    """Require every modeled completed frame, not just the last one's latency.

    This is a necessary cycle-budget gate for the 125MHz implementation. It
    does not certify camera cadence, arbitrary transforms or measured board
    throughput. Older logs without per-job observations need a fresh model.
    """
    payload=(simulation/'run.log').read_bytes()
    log='\n'.join(payload.decode('utf-8',errors='replace').splitlines())
    rows=[(int(n),int(c)) for n,c in re.findall(r'^FRAME_GEOMETRY job=(\d+) geometry_cycles=(\d+)$',log,re.M)]
    summary=re.findall(r'^GEOMETRY_BUDGET jobs=(\d+) max_cycles=(\d+) clock_hz=125000000 minimum_fps=30$',log,re.M)
    completed=re.findall(r'TB_VIDEO_MEMORY_CORE_PASS bytes=\d+ good=\d+ processed=(\d+) geometry_cycles=\d+',log)
    if (len(rows)<3 or [n for n,_ in rows]!=list(range(1,len(rows)+1)) or
            len(summary)!=1 or len(completed)!=1 or int(completed[0])!=len(rows)):
        raise ValueError('Complete per-frame geometry cycle evidence is required')
    cycles=[c for _,c in rows]
    if tuple(map(int,summary[0]))!=(len(rows),max(cycles)) or min(cycles)<=0:
        raise ValueError('Geometry budget summary does not match individual frames')
    if max(cycles)>125000000//30:
        raise ValueError('Modeled geometry exceeds 1080p30 cycle budget: '+str(cycles))
    return dict(frame_cycles=cycles,max_cycles=max(cycles),clock_hz=125000000,
                minimum_fps=30,run_log_sha256=hashlib.sha256(payload).hexdigest(),
                physical_fps_verified=False)


def verified_display_evidence(simulation):
    """Require real scanout traffic and distinct, checked, non-underflow frames."""
    log=(simulation/'run.log').read_text(encoding='utf-8',errors='replace')
    rows=re.findall(r'DISPLAY_CORE_PASS new=(\d+) repeat=(\d+) checked_pixels=(\d+) failed=(\d+) underflow=(\d+)',log)
    if len(rows)!=1:
        raise ValueError('Real display/context/DMA CDC model result is required')
    new,repeat,pixels,failed,underflow=map(int,rows[0])
    if new<3 or pixels<1920*1080*3 or failed or underflow:
        raise ValueError('Display model has incomplete, failed or underflow frames')
    return dict(new_frames=new,repeat_frames=repeat,checked_pixels=pixels,
                failed_frames=failed,underflow_events=underflow,physical_display_verified=False)


def verified_host_companions(host, project):
    """Read the exact host files used by the offline verification process.

    A package-time hash of mutable live files cannot bind them to an earlier
    PASS. The verifier freezes its script and import closure before decoding;
    require that explicit snapshot and compare every byte before archiving.
    """
    names = ['host/scripts/verify_fpga_rgb_vectors.py']
    names += ['host/src/pango_video/'+name+'.py' for name in
              ('__init__', 'fpga_rgb_control', 'raw8_boot', 'protocol',
               'cli', 'reassembly', 'receiver', 'storage')]
    recorded = host.get('companion_files_sha256', {})
    if set(recorded) != set(names):
        raise ValueError('host verification must bind the complete companion source snapshot')
    snapshot_name = host.get('companion_snapshot_directory')
    if not snapshot_name:
        raise ValueError('host verification has no frozen companion directory')
    snapshot = Path(snapshot_name).resolve()
    if not snapshot.is_relative_to(project / 'host/reports'):
        raise ValueError('host companion snapshot lies outside host reports')
    if not host.get('companion_snapshot_intact'):
        raise ValueError('host verification did not preserve its source snapshot')
    script = snapshot / 'host/scripts/verify_fpga_rgb_vectors.py'
    if Path(host.get('verification_script_path', '')).resolve() != script:
        raise ValueError('host verification did not execute its frozen script')
    # Bind import provenance as well as archived file contents: the worker
    # must actually load these modules from the same isolated source tree.
    expected_imports = {'pango_video': snapshot / 'host/src/pango_video/__init__.py'}
    expected_imports.update({
        'pango_video.'+name: snapshot / ('host/src/pango_video/'+name+'.py')
        for name in ('fpga_rgb_control', 'raw8_boot', 'protocol', 'cli',
                     'reassembly', 'receiver', 'storage')})
    imports = host.get('companion_import_paths', {})
    if set(imports) != set(expected_imports):
        raise ValueError('host verification did not record every companion import')
    for name, path in expected_imports.items():
        if Path(imports[name]).resolve() != path:
            raise ValueError('host verifier imported outside its source snapshot: '+name)
    payloads = {}
    for name in names:
        path = (snapshot / name).resolve()
        if not path.is_relative_to(snapshot):
            raise ValueError('host companion resolves outside its snapshot: '+name)
        payload = path.read_bytes()
        if hashlib.sha256(payload).hexdigest() != recorded[name]:
            raise ValueError('verified host companion changed: '+name)
        payloads[name] = payload
    return payloads


def verify_bitgen_configuration(build, database, stream, top):
    """Read native XML/report settings rather than assuming shared-pin defaults.

    PDS 2022.2-SP6.4 writes XML to bgr.db. The installed guide says shared
    pins default to user release; the final artifact must prove that setting.
    SCBV is recorded as configured, not treated as electrical signoff: this
    board uses both L4/L5, where the official guide says SCBV has no effect.
    """
    settings = {}
    for row in ET.parse(build / 'generate_bitstream/bgr.db').iter('row'):
        values = [cell.text or '' for cell in row.findall('data')]
        if len(values) == 2:
            if values[0] in settings and settings[values[0]] != values[1]:
                raise ValueError('ambiguous native bitgen setting: '+values[0])
            settings[values[0]] = values[1]
    expected = {'Part': 'PG2L100H-6FBG676', 'Top Module': top,
                'Persist Pin': 'Release For USER', 'Create Bit File': 'true',
                'Disable Cyclic Redundancy Checking(CRC)': 'false',
                'Write DRM Data': 'true', 'Unused IO Status': 'UNUSED',
                'Set Configuration Bank Voltage(SCBV)': 'High Voltage'}
    for name, value in expected.items():
        if settings.get(name) != value:
            raise ValueError('unexpected native bitgen setting: '+name)
    # The textual report records the actual input/output and installed build.
    # Require the routed database, never a placement or old candidate input.
    report = (build / 'generate_bitstream' / (top+'.bgr')).read_text(errors='replace')
    if ('2022.2-SP6.4 <build 146967>' not in report or
            database.as_posix() not in report or stream.as_posix() not in report or
            'Generating Programming File done.' not in report):
        raise ValueError('native bitgen report does not identify the expected artifacts')
    return settings


def main():
    """Refuse missing/failed builds; preserve all original runs and packages."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board-build', type=Path, required=True)
    parser.add_argument('--simulation', type=Path, required=True)
    parser.add_argument('--host-verification', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    build = args.board_build.resolve()
    simulation = args.simulation.resolve()
    board = json.loads((build / 'result.json').read_text(encoding='utf-8'))
    model = json.loads((simulation / 'result.json').read_text(encoding='utf-8'))
    # Keep the exact report bytes validated here; the archive must not reread
    # a mutable report after checking its source/vector binding.
    host_report_bytes = args.host_verification.read_bytes()
    host = json.loads(host_report_bytes.decode('utf-8'))
    stream = build / 'generate_bitstream/pango_video_system.sbit'
    if (board.get('native_exit') != 0 or board.get('errors') or not board.get('internal_timing_met')
            or not board.get('snapshot_intact') or not stream.is_file()):
        raise ValueError('native PnR/min_max/bitstream gate has not passed')
    if (board.get('bitstream_sha256') != digest(stream) or
            board.get('bitstream_bytes') != stream.stat().st_size):
        raise ValueError('native recorded bitstream bytes changed')
    if (not model.get('passed') or not model.get('full_frame') or not model.get('snapshot_intact')
            or not model.get('snapshot_test') or not model.get('control_test')):
        raise ValueError('complete synthetic full-frame regression required')
    geometry_budget=verified_geometry_budget(simulation)
    if not model.get('display_test'):
        raise ValueError('Full-frame model must include actual display read traffic')
    display_evidence=verified_display_evidence(simulation)
    if not host.get('passed') or host.get('snapshot_bytes') != 12441600:
        raise ValueError('complete 1080p pair host decoding required')
    if host.get('hardware_tested') or model.get('hardware_tested'):
        raise ValueError('this packaging path records synthetic evidence only')
    if Path(host.get('input_directory', '')).resolve() != simulation:
        raise ValueError('host evidence belongs to a different simulation')
    vector_names = {'snapshot_datagrams.bin', 'snapshot_descriptors.bin'}
    if set(host.get('input_sha256', {})) != vector_names:
        raise ValueError('host evidence must bind both exact simulation vector files')
    for name, expected in host['input_sha256'].items():
        if digest(simulation / name) != expected:
            raise ValueError('host vector input changed: '+name)
    checkpoint = json.loads((build / 'bitgen_checkpoint.json').read_text(encoding='utf-8'))
    if not checkpoint.get('checkpoint_intact') or checkpoint.get('native_exit') != 0:
        raise ValueError('same routed database/STA bitgen proof required')
    for key, name in (('timing_report', 'report_timing/pango_video_system.rtr'),
                      ('routed_database', 'place_route/pango_video_system_pnr.adf')):
        if digest(build / name) != checkpoint['after'][key]:
            raise ValueError('post-bitgen checkpoint changed: '+name)
    bitgen_configuration = verify_bitgen_configuration(
        build, build / 'place_route/pango_video_system_pnr.adf', stream, 'pango_video_system')
    sources = json.loads((build / 'sources.json').read_text(encoding='utf-8'))
    # Simulation evidence must describe the actual frozen native RTL. A prior
    # passing image is not a substitute after any implementation change.
    model_sources = json.loads((simulation / 'sources.json').read_text(encoding='utf-8'))
    # A matching manifest alone is insufficient if its frozen test source was
    # edited after simulation. Verify the actual archived model input bytes.
    for name, expected in model_sources.items():
        if digest(simulation / 'source' / name) != expected:
            raise ValueError('immutable simulation source changed: '+name)
    for name, expected in sources.items():
        if name.startswith('rtl/') and name in model_sources and model_sources[name] != expected:
            raise ValueError('simulation/native RTL mismatch: '+name)
    for name, expected in sources.items():
        if digest(build / 'source' / name) != expected:
            raise ValueError('immutable native source changed: '+name)
    # The integrated board requires an explicit PC boot entity. Bundle its
    # frozen protocol guide and the verified offline decoder with its import closure,
    # so the evidence can be decoded without reconstructing host dependencies.
    # Archiving these files neither opens hardware nor sends a boot command.
    project = fpga.parent
    companion_payloads = verified_host_companions(host, project)
    companion_payloads['fpga/config/integration/PC_RGB_CONTROL.md'] = (
        build / 'source/config/integration/PC_RGB_CONTROL.md').read_bytes()
    companion_names = list(companion_payloads)
    companion_hashes = {name: hashlib.sha256(data).hexdigest()
                        for name, data in companion_payloads.items()}
    # Retain the packaging gate implementation that assembled this evidence,
    # together with the separately frozen native build/host verification code.
    package_script_bytes = Path(__file__).read_bytes()
    package = fpga / 'release/candidates' / datetime.now().strftime('%Y%m%d_%H%M%S') / 'pango_video_system'
    package.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(stream, package / stream.name)
    (package / (stream.name+'.sha256')).write_text(digest(stream)+'  '+stream.name+'\n', encoding='ascii')
    # Preserve the actual native input source, including generated IP and
    # constraints, rather than reconstructing it from a mutable working tree.
    # Resource variants also retain their full-board source/behavior evidence;
    # these records supplement, and never replace, the routed timing gate.
    # An optional verification mask is preserved only from this same native
    # bitgen directory; it is evidence, not an additional release prerequisite.
    with zipfile.ZipFile(package / 'source_and_evidence.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((build / 'source').rglob('*')):
            if path.is_file():
                archive.write(path, 'source/'+path.relative_to(build / 'source').as_posix())
        for name in ('sources.json', 'flow.tcl', 'result.json', 'build_script.py', 'native_bitgen.py',
                     'mapped_copy.json', 'clone_mapped_video_system.py',
                     'source_identity.json',
                     'combined_board_evidence.json',
                     'host_companion_verification.json',
                     'variant_origin.json', 'source_differences.json',
                     'ordering_board_evidence.json', 'network_recovery_evidence.json',
                     'promoted_source.json', 'annotation_corrections.json',
                     'reviews/frame_order_matrix_probe_20261014.md',
                     'reviews/frame_order_D_recovery_review_20261014.md',
                     'reviews/router_long_run_diagnostics_20261014_1753.md',
                     'reviews/router_iteration8_comparison_20261014.md',
                     'reviews/router_fallback_review_after_B_failure_20261014.md',
                     'reviews/resource_fallback_audit_20261014.md',
                     'reviews/frame_fabric_storage_sharing_audit_20261014.md',
                     'reviews/ram_delay_review_20261014.md',
                     'reviews/router_progress_review_20261014.md',
                     'reviews/reset_exception_review_20261014.md',
                     'reviews/package_companion_source_gate_20261014.json',
                     'reviews/package_usage_host_binding_review_20261014.md',
                     'reviews/native_router_options_supplement_20261014.md',
                     'reviews/installed_router_help_supplement_20261014.json',
                     'reviews/current_map_congestion_review_20261014.md',
                     'reviews/token_generation_probe_20261014.md',
                     'reviews/cache_tag_independent_review_20261014.md',
                     'reviews/cache_tag_probe_20261014.md',
                     'reviews/combined_H_recovery_review_20261014.md',
                     'bitgen_from_checkpoint.tcl', 'bitgen_checkpoint.json',
                     'bitgen_from_checkpoint.pds', 'generate_bitstream/bgr.db',
                     'generate_bitstream/pango_video_system.smsk',
                     'generate_bitstream/pango_video_system.bgr', 'generate_bitstream/run.log',
                     'report_timing/pango_video_system.rtr', 'synthesize/pango_video_system.snr',
                     'device_map/pango_video_system.pcf', 'place_route/pango_video_system_pnr.adf',
                     'place_route/pango_video_system.prr', 'place_route/clock_utilization.txt',
                     'constraint_check/constraint_check.ccr'):
            path = build / name
            if path.is_file():
                archive.write(path, 'native/'+name)
        # The original flow may stop at MAP. Retain the exact successful
        # standalone physical/STA scripts and logs used after that checkpoint,
        # including explicit device-specific routing settings and source gates.
        if board.get('resume_evidence'):
            resume = Path(board['resume_evidence']).resolve()
            if not resume.is_relative_to(build):
                raise ValueError('resume evidence lies outside native build')
            for name in ('resume_script.py', 'native_bitgen.py', 'place_route.tcl',
                         'place_route.log', 'report_timing.tcl', 'report_timing.log',
                         'gen_bit_stream.log', 'result.json'):
                path = resume / name
                if path.is_file():
                    archive.write(path, 'native/resume/'+name)
        for name in ('sources.json', 'result.json', 'run.log'):
            archive.write(simulation / name, 'simulation/'+name)
        for name in ('snapshot_datagrams.bin', 'snapshot_descriptors.bin', 'simulation_script.py',
                     'source/sim/tb_video_memory_core.sv', 'source/sim/video_core_display_fixture.sv'):
            archive.write(simulation / name, 'simulation/'+name)
        archive.writestr('host/verification.json', host_report_bytes)
        archive.writestr('release/package_video_system.py', package_script_bytes)
        for name in companion_names:
            archive.writestr('usage/'+name, companion_payloads[name])
    manifest = {
        'schema': 'pango_video_system.candidate.v1', 'device': 'PG2L100H', 'package': 'FBG676',
        'speedgrade': '-6', 'pds': '2022.2-SP6.4', 'top': 'pango_video_system',
        'native_build': str(build), 'simulation': str(simulation),
        'host_verification': str(args.host_verification.resolve()),
        'host_verification_sha256': hashlib.sha256(host_report_bytes).hexdigest(),
        'host_companion_snapshot': host['companion_snapshot_directory'],
        'package_script_sha256': hashlib.sha256(package_script_bytes).hexdigest(),
        'bitstream': stream.name, 'bitstream_bytes': stream.stat().st_size,
        'bitstream_sha256': digest(stream), 'native_internal_min_max_met': True,
        'native_bitgen_configuration': bitgen_configuration,
        'integrated_fpga_video_path': True, 'full_system_hardware_verified': False,
        'programmed': False, 'external_io_timing_verified': False,
        'external_io_electrical_verified': False,
        'physical_1080p30_verified': False, 'calibration_source_stage': 'unverified',
        'modeled_geometry_budget': geometry_budget,
        'modeled_display': display_evidence,
        'features': ['RAW8 DVP / SCCB identity + readback / fixed exposure',
                     'native DDR / verified writes / five frame pools',
                     'FPGA ISP S1 / connected identity CCM / source statistics',
                     'source-locked projective + lens mapping / RGB bilinear',
                     'fixed reference tone LUT disabled/pre/post modes',
                     'HDMI 1080p30 raster / coherent related serializer clocks',
                     'S0 Ethernet / same-source RGB snapshot copy + export',
                     'PC boot / status / mode / geometry / old snapshot parameter readback'],
        'mcu_external_connection': 'deferred by user; pose_status=no_samples',
        'automatic_gamma': False, 'dynamic_lut_upload': False,
        'companion_files_sha256': companion_hashes,
        'source_archive_sha256': digest(package / 'source_and_evidence.zip'),
    }
    (package / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    (package / 'README.md').write_text(
        '# FPGA 集成视频工程候选位流\n\n'
        '此目录由实际 PG2L100H/FBG676/-6 原生布线及 min/max 时序通过后生成，包含 '
        'RAW8→FPGA ISP→透视/镜头矫正→HDMI，以及 S0 网络、同源 RGB 快照和 PC 参数控制。\n\n'
        '下载文件：`pango_video_system.sbit`；校验和见 `.sha256`。完整冻结源、IP、约束和验证结果在 '
        '`source_and_evidence.zip`。使用前需由 PC 专用 V1/0x71 启动实体显式配置 epoch/MAC/IP/ports，'
        '运行协议见证据包内 `usage/fpga/config/integration/PC_RGB_CONTROL.md`；'
        '配套离线编解码源码及验证脚本位于 `usage/host/`。\n\n'
        '这是离线集成候选，未烧录、未完成实板功能/1080p30/外部电气与光学验收。'
        '部分板级输出drive/slew未显式指定，原生约束检查记录保存在证据包；不能视为外部电气签核。'
        'MCU 外部连接按用户范围暂缓；'
        '无姿态样本不执行经校准运动补偿。增强为固定参考曲线，不包含自动 Gamma 或运行期 LUT 上传。'
        '完整能力和来源标志见 manifest，不能将此文件当作整机已验收证明。\n', encoding='utf-8')
    print(package)
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == '__main__':
    main()
