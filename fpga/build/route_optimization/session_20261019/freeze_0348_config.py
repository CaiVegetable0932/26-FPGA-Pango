"""Explicit scope for the 03:48 terminal checkpoint; active proofs excluded."""
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[4]
R=ROOT/'fpga/build/route_optimization'
S=Path(__file__).resolve().parent
proofs=[R/n for n in ['proc150_job_cdc_20261020_033744_433853','proc150_job_cdc_20261020_033751_467884','proc150_geometry_20261020_034010_472654']]
proofs += [ROOT/'fpga/build/full_integration_20261013'/n for n in ['verilator_20261020_034204_198227','verilator_20261020_034331_201913','sim_20261020_034431_720936']]
cases=[R/'pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_033156_803361',
 R/'writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_034224_150394']
trees=[ROOT/'fpga/experiments/proc150',R/'proc150_video_model_20261020_034156_238730',R/'proc150_video_model_20261020_034322_763921']
files=[Path(__file__).resolve(),S/'update_status_0348.py']
files += [ROOT/'fpga/scripts'/n for n in ['sim_video_verilator.py','processing_job_cdc.py'] if n!='processing_job_cdc.py']
files += [ROOT/'fpga/scripts'/n for n in ['verify_processing_job_cdc.py','verify_geometry_processing_domain.py','prepare_proc150_video_model.py','probe_processing_domain_mapping.py','verify_pool_local_tokens.py']]
files += [ROOT/'fpga/reports'/n for n in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md','regional_verification_plan_20261019.md','control_locality_review_20261020.md']]
command=[sys.executable,str(ROOT/'fpga/scripts/freeze_regional_checkpoint.py'),'--label','0348','--session',str(S),
 '--proof',*map(str,proofs),'--native-case',*map(str,cases),'--input-tree',*map(str,trees),'--file',*map(str,files)]
subprocess.run(command,cwd=ROOT,check=True)
