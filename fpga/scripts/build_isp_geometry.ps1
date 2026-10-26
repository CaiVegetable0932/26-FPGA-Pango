# Purpose: isolated target-device block compile/synthesis/PnR; no bitstream/programming.
# PDS 2022.2-SP6.4 native top-level flow, physically legal bounded-I/O harness.
# Harness I/O has no board-interface timing sign-off; internal min/max is timed.
param([ValidateSet('lens_inverse_map','rgb_bilinear','raw8_isp','geometry_rgb_pipeline')][string]$Top='lens_inverse_map',
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$RunRoot='',
 [int]$PlacementSeed=7,[int]$MaxControlChain=4)
$ErrorActionPreference='Stop'
$taskFpga=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if(!$RunRoot){$RunRoot=Join-Path $taskFpga ('build/isp_geometry/pds_'+$Top+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))}
$taskRun=[IO.Path]::GetFullPath($RunRoot)
if(!$taskRun.StartsWith((Join-Path $taskFpga 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'RunRoot must be within fpga/build'}
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskHarness=@{lens_inverse_map='lens_timing_top';rgb_bilinear='bilinear_timing_top';raw8_isp='isp_timing_top';geometry_rgb_pipeline='geometry_timing_top'}[$Top]
# Current affine/lens harnesses use no projective divider; historic PDS
# snapshots remain reproducible only with their matching frozen source list.
$taskSourcePaths=@('rtl/isp/isp_line_store.sv','rtl/isp/raw8_isp.sv','rtl/isp/rgb_colour_matrix.sv','rtl/isp/rgb_frame_statistics.sv',
 'rtl/geometry/affine_ray_stepper.sv','rtl/geometry/signed_mult32_pipe.sv','rtl/geometry/lens_inverse_map.sv','rtl/geometry/unsigned_mult32_pipe.sv','rtl/geometry/signed_mult40_unsigned40_pipe.sv',
 'rtl/geometry/rgb_cache_bank.sv','rtl/geometry/rgb_tile_cache.sv','rtl/geometry/rgb_bilinear.sv','rtl/geometry/gamma_lut_bank.sv','rtl/geometry/rgb_enhance.sv','rtl/geometry/geometry_rgb_pipeline.sv','rtl/geometry/algorithm_timing_top.sv')
$taskManifest=@();$taskFlow=@()
$taskFlow+='set_dir -impl_directory {'+(Join-Path $taskRun 'implementation').Replace('\','/')+'}'
$taskFlow+='set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676'
foreach($taskRelative in $taskSourcePaths){
 $taskPath=Join-Path $taskFpga $taskRelative
 $taskManifest+=[ordered]@{path=$taskRelative;sha256=(Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLower()}
 # Build immutable snapshots so concurrent work on other blocks cannot alter
 # what the tool reads; original hashes explicitly define the reported version.
 $taskCopy=Join-Path $taskRun ('sources/'+(Split-Path $taskPath -Leaf))
 New-Item -ItemType Directory -Path (Split-Path $taskCopy -Parent) -Force | Out-Null
 Copy-Item -LiteralPath $taskPath -Destination $taskCopy
 $taskFlow+='add_design {'+$taskCopy.Replace('\','/')+'}'
}
$taskFdc=Join-Path $taskRun 'block.fdc'
@('create_clock -name proc_clk -period 6.666667 [get_ports clk]',
 '# No invented board delays, no broad exceptions: this is a standalone internal block.') | Set-Content -LiteralPath $taskFdc -Encoding ascii
$taskFlow+='add_constraint {'+$taskFdc.Replace('\','/')+'}'
$taskFlow+='compile -top_module '+$taskHarness
$taskFlow+='synthesize -ads -rw_check_on_ram -resource_sharing false -fanout_guide 64 -selected_syn_tool_opt 2'
$taskFlow+='dev_map'
# Installed pnr -help confirms CE/RS chain limit syntax. Bound control-chain
# propagation physically; retain the same clock constraint and all data paths.
$taskFlow+='pnr -congest_overlap_limit 20 -action_timeout 15 -max_ctrl_chain_length '+$MaxControlChain+' -gplace_seed '+$PlacementSeed
$taskFlow+='report_timing -delay_type min_max -max_path 10 -report_exception TRUE'
$taskTcl=Join-Path $taskRun ($Top+'.tcl')
$taskFlow | Set-Content -LiteralPath $taskTcl -Encoding ascii
@(('tcl2prj -tcl {'+$taskTcl.Replace('\','/')+'}'), 'puts "ALGORITHM_PROJECT_GENERATED"') |
 Set-Content -LiteralPath (Join-Path $taskRun 'create.tcl') -Encoding ascii
$taskManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskRun 'source_manifest.json') -Encoding UTF8
$taskShell=Join-Path $PdsHome 'bin/pds_shell.exe'
Push-Location $taskRun
try{
 & $taskShell -file (Join-Path $taskRun 'create.tcl') -work_dir $taskRun 2>&1 | Tee-Object generation.log
 if($LASTEXITCODE -ne 0 -or (Get-Content generation.log -Raw) -match '(?m)^E:|Check license failed'){throw 'PDS native generation failed'}
 # PDS defaults to its entire eight-stage flow even when Tcl omitted bitstream
 # commands. Official PDS User Guide section 5.3: -run report_timing stops at STA.
 & $taskShell -project (Join-Path $taskRun ($Top+'.pds')) -work_dir $taskRun -run report_timing 2>&1 | Tee-Object build.log
 $taskExit=$LASTEXITCODE
 $taskTimingPath=Join-Path $taskRun ('report_timing/'+$taskHarness+'.rtr')
 $taskStaPassed=$false;$taskCornerChecks=@()
 if(Test-Path -LiteralPath $taskTimingPath){
  $taskTimingText=Get-Content -LiteralPath $taskTimingPath -Raw
  # Require both setup and hold in both corners, including nonzero endpoints.
  # Native exit zero alone cannot mean the requested clock actually met timing.
  $taskRows=[regex]::Matches($taskTimingText,'(?m)^\s*proc_clk\s+proc_clk\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$')
  foreach($taskRow in $taskRows){$taskCornerChecks+=[ordered]@{worst_ns=[double]$taskRow.Groups[1].Value;total_ns=[double]$taskRow.Groups[2].Value;failing_endpoints=[int]$taskRow.Groups[3].Value;endpoints=[int]$taskRow.Groups[4].Value}}
  $taskStaPassed=$taskRows.Count -ge 4 -and @($taskCornerChecks | Where-Object {$_.worst_ns -lt 0 -or $_.failing_endpoints -ne 0 -or $_.endpoints -eq 0}).Count -eq 0
 }
 [ordered]@{top=$Top;harness=$taskHarness;native_exit=$taskExit;target='PG2L100H FBG676 -6';clock_target_mhz=150;placement_seed=$PlacementSeed;max_control_chain=$MaxControlChain;
  standalone_internal_sta_passed=$taskStaPassed;timing_report=$taskTimingPath;corner_checks=$taskCornerChecks;
  hardware_tested=$false;programmed=$false;board_io_timing_verified=$false;scope='standalone registered block harness; inspect native timing/resource reports'} |
  ConvertTo-Json -Depth 5 | Set-Content result.json
 if($taskExit -ne 0 -or (Get-Content build.log -Raw) -match '(?m)^E:|Check license failed'){throw 'PDS block flow failed; inspect build.log'}
 if(!$taskStaPassed){throw 'PDS finished but 150 MHz internal STA did not pass; inspect result.json and native rtr'}
 Write-Output "ISP_GEOMETRY_PDS_FLOW_FINISHED $taskRun"
}finally{Pop-Location}





































