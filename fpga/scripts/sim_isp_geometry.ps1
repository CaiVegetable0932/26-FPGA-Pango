# Purpose: reproducible golden/RTL regression for algorithm 06, no hardware access.
# Every native command is checked and artifacts remain in a fresh FPGA build child.
param([ValidateSet('ModelSim','Icarus')][string]$Simulator='Icarus',
 [string]$ModelSimHome='E:/ModelsimSE/win64',[string]$IcarusHome='',
 [string]$Python='python',[string]$RunRoot='', [switch]$ReuseVectors,[switch]$FullFrame)
$ErrorActionPreference='Stop'
$taskFpga=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if(!$RunRoot){$RunRoot=Join-Path $taskFpga ('build/isp_geometry/run_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))}
$taskRun=[IO.Path]::GetFullPath($RunRoot)
if(!$taskRun.StartsWith((Join-Path $taskFpga 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'RunRoot must be within fpga/build'}
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskVectors=Join-Path $taskRun 'vectors'
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'}
# Reuse is only for debugging RTL against an already generated immutable golden.
if(!$ReuseVectors){
 & $Python -B (Join-Path $taskFpga 'sim/test_isp_geometry.py') 2>&1 | Tee-Object (Join-Path $taskRun 'unit_tests.log')
 if($LASTEXITCODE){throw 'Golden contract tests failed'}
 & $Python -B (Join-Path $taskFpga 'scripts/generate_isp_geometry_vectors.py') --output $taskVectors 2>&1 | Tee-Object (Join-Path $taskRun 'model.log')
 if($LASTEXITCODE){throw 'Golden generation/precision failed'}
} elseif(!(Test-Path -LiteralPath (Join-Path $taskVectors 'model_audit.json'))){throw 'No golden to reuse'}
$taskSources=@('rtl/isp/isp_line_store.sv','rtl/isp/raw8_isp.sv','rtl/isp/rgb_colour_matrix.sv','rtl/isp/rgb_frame_statistics.sv',
 'rtl/geometry/affine_ray_stepper.sv','rtl/geometry/signed_mult32_pipe.sv','rtl/geometry/lens_inverse_map.sv',
 # Affine/lens arithmetic remains active; the retired perspective divider
 # and its fixture are intentionally absent from this current regression.
 'rtl/geometry/unsigned_mult32_pipe.sv','rtl/geometry/signed_mult40_unsigned40_pipe.sv',
 'rtl/geometry/rgb_cache_bank.sv','rtl/geometry/rgb_tile_cache.sv','rtl/geometry/rgb_bilinear.sv','rtl/geometry/gamma_lut_bank.sv','rtl/geometry/rgb_enhance.sv','rtl/geometry/geometry_rgb_pipeline.sv',
 'sim/tb_isp_geometry.sv','sim/tb_rgb_tile_cache.sv','sim/tb_geometry_pipeline.sv','sim/tb_algorithm_arithmetic.sv','sim/tb_lens_overflow.sv') | ForEach-Object {Join-Path $taskFpga $_}
$taskTests=@('tb_signed_mult32_pipe','tb_rgb_colour_matrix','tb_lens_inverse_map','tb_lens_overflow','tb_raw8_isp','tb_rgb_enhance','tb_rgb_tile_cache','tb_rgb_tile_cache_quad','tb_rgb_tile_cache_32x8','tb_affine_statistics','tb_geometry_rgb_pipeline','tb_geometry_rgb_pipeline_partial')
if($FullFrame){$taskTests+=@('tb_raw8_isp_1080p','tb_geometry_rgb_pipeline_1080p')}
$taskResults=@()
Push-Location $taskRun
try {
 if($Simulator -eq 'ModelSim'){
  & "$ModelSimHome/vlib.exe" work
  if($LASTEXITCODE){throw 'vlib failed'}
  & "$ModelSimHome/vlog.exe" -sv -work work @taskSources 2>&1 | Tee-Object compile.log
  if($LASTEXITCODE){throw 'vlog failed'}
 }
 foreach($taskTest in $taskTests){
  if($Simulator -eq 'Icarus'){
   & "$IcarusHome/iverilog.exe" -g2012 -s $taskTest -o "$taskTest.vvp" @taskSources 2>&1 | Tee-Object "$taskTest.compile.log"
   if($LASTEXITCODE){throw "Icarus compile failed: $taskTest"}
   & "$IcarusHome/vvp.exe" "$taskTest.vvp" "+VECTORS=$($taskVectors.Replace('\','/'))" 2>&1 | Tee-Object "$taskTest.log"
  } else {
   & "$ModelSimHome/vsim.exe" -c -lib ./work $taskTest "+VECTORS=$($taskVectors.Replace('\','/'))" -do 'onerror {quit -code 1}; run -all; quit -f' 2>&1 | Tee-Object "$taskTest.log"
  }
  $taskExit=$LASTEXITCODE;$taskText=Get-Content "$taskTest.log" -Raw
  $taskPassed=$taskExit -eq 0 -and $taskText -match '_PASS' -and $taskText -notmatch '_FAIL|_TIMEOUT|\*\* (Error|Fatal):'
  $taskResults+=[ordered]@{test=$taskTest;passed=$taskPassed;native_exit=$taskExit}
 }
 $taskPassed=@($taskResults | Where-Object {!$_.passed}).Count -eq 0
 [ordered]@{passed=$taskPassed;simulator=$Simulator;tests=$taskResults;hardware_tested=$false;pds_pnr_tested=$false;scope='algorithm 06 local golden and RTL'} |
  ConvertTo-Json -Depth 6 | Set-Content result.json
 if(!$taskPassed){throw 'Algorithm 06 RTL regression failed; see result.json'}
 Write-Output "ISP_GEOMETRY_REGRESSION_PASS $taskRun"
} finally {Pop-Location}





























































