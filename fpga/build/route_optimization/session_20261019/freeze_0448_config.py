"""Archive terminal 04:48 evidence; all current board/full-frame runs excluded."""
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[4];S=Path(__file__).resolve().parent
R=ROOT/'fpga/build/route_optimization';B=ROOT/'fpga/build/full_integration_20261013'
proofs=[R/n for n in ['proc150_reset_20261020_040449_764699','proc150_tile_cdc_20261020_041036_095741',
 'proc150_tile_cdc_20261020_041054_271536','proc150_geometry_20261020_041309_649112',
 'proc150_geometry_20261020_042818_034553','proc150_tile_faults_20261020_042003_078762',
 'proc150_tile_faults_20261020_042419_779592','proc150_tile_faults_20261020_042448_053067',
 'proc150_tile_faults_20261020_042552_100909','proc150_tile_faults_20261020_042552_140908',
 'proof_supervisor_test_20261020_042941_232536']]
models=[B/n for n in ['verilator_20261020_034441_923014','verilator_20261020_035853_729207',
 'verilator_20261020_041259_374226','verilator_20261020_041408_348937',
 'verilator_20261020_043315_535015','verilator_20261020_043626_233147']]
proofs+=models+[B/n for n in ['sim_20261020_041249_181564','sim_20261020_042704_136945','sim_20261020_043508_583868']]
pool=R/'pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599'
cases=sorted(pool.glob('regional_route_*'))
trees=[ROOT/'fpga/experiments/proc150',R/'pool_chunk8_20261020_034402_468921',
 R/'pool_writer_composed_20261020_041215_809753',R/'geometry_recovery_20261020_042541_182177',
 R/'geometry_recovery_20261020_042634_206552',R/'proc150_video_model_20261020_041342_818683',
 R/'proc150_video_model_20261020_042828_363869',R/'proc150_video_model_20261020_043529_242103',
 R/'proc150_board_20261020_044427_625524']
trees += [p for p in R.glob('proc150_tile_faults_*') if not (p/'result.json').exists()]
files=[Path(__file__).resolve(),S/'update_status_0448.py',S/'selected_main13_source_check_0448.json',
 S/'adjust_mapping_scope_0436.py',S/'extend_board_snapshot_0446.py']
scripts=['build_video_system.py','prepare_proc150_board.py','compose_pool_writer_finalist.py','prepare_geometry_recovery.py',
 'prepare_proc150_video_model.py','prepare_tile_refill_domain.py','probe_processing_domain_mapping.py',
 'proof_supervisor.py','test_proof_supervisor.py','sim_video_verilator.py','verify_geometry_processing_domain.py',
 'verify_processing_domain_reset.py','verify_tile_domain_faults.py','verify_tile_refill_cdc.py','test_proc150_board_gate.py']
files += [ROOT/'fpga/scripts'/n for n in scripts]
for model in models:
    for n in ['snapshot_datagrams.bin','snapshot_descriptors.bin','CMakeLists.txt','build_anchor.cpp']:
        if (model/n).exists():files.append(model/n)
files += [ROOT/'fpga/reports'/n for n in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md',
 'regional_verification_plan_20261019.md','control_locality_review_20261020.md']]
proofs += sorted(R.glob('proc150_board_gate_*'))
subprocess.run([sys.executable,str(ROOT/'fpga/scripts/freeze_regional_checkpoint.py'),'--label','0448','--session',str(S),
 '--proof',*map(str,proofs),'--native-case',*map(str,cases),'--native-screen',str(pool),
 '--native-synthesis',str(R/'proc150_mapping_20261020_043616_243611'),
 '--input-tree',*map(str,trees),'--file',*map(str,files)],cwd=ROOT,check=True)
