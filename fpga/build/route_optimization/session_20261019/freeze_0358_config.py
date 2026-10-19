"""Freeze writer release proofs and completed CDC experiments; no active runs."""
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[4];S=Path(__file__).resolve().parent
R=ROOT/'fpga/build/route_optimization';B=ROOT/'fpga/build/full_integration_20261013'
model=B/'verilator_20261020_033308_185785'
proofs=[model,R/'proc150_read_prefetch_20261020_035431_296216',R/'proc150_geometry_20261020_035602_578166',
 B/'verilator_20261020_035621_934924',R/'pool_chunk8_20261020_034402_468921/differential_20261020_034414_100718']
cases=[R/'writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034544_435841']
synthesis=[R/'proc150_mapping_20261020_034856_847709']
trees=[S/'writer_pipeline_finalist',S/'writer_pipeline_promotion_20261020',ROOT/'fpga/experiments/proc150',
 R/'proc150_video_model_20261020_035612_841416',ROOT/'host/reports/fpga_rgb_vectors_20261020_035641_996920_companions']
files=[Path(__file__).resolve(),S/'fix_handoff_0401.py',S/'update_status_0358.py',S/'promote_writer_pipeline_0358.py',S/'writer_three_seed_0358.json',
 ROOT/'fpga/rtl/memory/frame_pixel_writer.sv',ROOT/'fpga/config/implementation_readiness.json',ROOT/'host/reports/.gitattributes',
 ROOT/'host/reports/fpga_rgb_vectors_20261020_035641_996920.json']
files += [model/n for n in ['snapshot_datagrams.bin','snapshot_descriptors.bin','CMakeLists.txt','build_anchor.cpp']]
files += [ROOT/'fpga/scripts'/n for n in ['prepare_read_cdc_prefetch.py','verify_read_cdc_prefetch.py','verify_geometry_processing_domain.py','prepare_proc150_video_model.py','probe_processing_domain_mapping.py']]
files += [ROOT/'fpga/reports'/n for n in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md','regional_verification_plan_20261019.md']]
subprocess.run([sys.executable,str(ROOT/'fpga/scripts/freeze_regional_checkpoint.py'),'--label','0358','--session',str(S),
 '--proof',*map(str,proofs),'--native-case',*map(str,cases),'--native-synthesis',*map(str,synthesis),
 '--input-tree',*map(str,trees),'--file',*map(str,files)],cwd=ROOT,check=True)
