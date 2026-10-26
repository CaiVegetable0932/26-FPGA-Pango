# Purpose: reproducible metadata/ownership and transaction drain regression.
# All generated files stay in fpga/build; no PDS project or hardware is touched.
param(
 [string]$IcarusHome='',
 [ValidateSet('all','manager')][string]$Case='all',
 [int]$Seed=51453990,
 [string]$Python='python'
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'}
$taskIcarus=(Resolve-Path -LiteralPath (Join-Path $IcarusHome 'iverilog.exe')).Path
$taskVvp=(Resolve-Path -LiteralPath (Join-Path $IcarusHome 'vvp.exe')).Path
$taskRun=Join-Path $taskFpga ('build/frame_manager/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Force $taskRun | Out-Null
& $Python (Join-Path $PSScriptRoot 'generate_frame_manager_layout.py')
if($LASTEXITCODE -ne 0){throw 'Frame layout generation failed'}
$taskResults=@()
Push-Location $taskRun
try {
 $taskSources=@('rtl/memory/frame_manager_pkg.sv','rtl/memory/frame_pool_bank.sv','rtl/memory/frame_manager.sv') | ForEach-Object {Join-Path $taskFpga $_}
 $taskCases=if($Case -eq 'all'){@('frame_manager','frame_manager_pressure','mini_frame_pool')}elseif($Case -eq 'manager'){@('frame_manager','frame_manager_pressure','mini_frame_pool')}else{@('frame_manager','frame_manager_pressure','mini_frame_pool')}
 foreach($taskCase in $taskCases){
  $taskInputs=@(if($taskCase -eq 'mini_frame_pool'){Join-Path $taskFpga 'rtl/mini_camera_diag/mini_frame_pool.v'}else{$taskSources})
  $taskInputs+=Join-Path $taskFpga "sim/tb_$taskCase.sv"
  Set-Content -LiteralPath "$taskCase.compile.log" -Value '' -Encoding utf8
  & $taskIcarus -g2012 -I (Join-Path $taskFpga 'rtl/memory') -s "tb_$taskCase" -o "$taskCase.vvp" @taskInputs 2>&1 | Tee-Object "$taskCase.compile.log"
  $taskCompileExit=$LASTEXITCODE
  # Purpose: record both compiler and simulator status; even a runnable output
  # after a compiler crash is a diagnostic, never a fully passing tool run.
  $taskRunExit=$null; $taskLog=''
  if(Test-Path -LiteralPath "$taskCase.vvp"){
   & $taskVvp "$taskCase.vvp" "+SEED=$Seed" 2>&1 | Tee-Object "$taskCase.log"
   $taskRunExit=$LASTEXITCODE; $taskLog=Get-Content -LiteralPath "$taskCase.log" -Raw
  }
  $taskMarker=if($taskCase -eq 'mini_frame_pool'){'FRAME_POOL_PASS'}else{$taskCase.ToUpper()+'_PASS'}
  $taskSimulationPass=$taskRunExit -eq 0 -and $taskLog -match $taskMarker -and $taskLog -notmatch '_FAIL|_TIMEOUT'
  $taskResults+=[ordered]@{case=$taskCase;compile_exit=$taskCompileExit;simulation_exit=$taskRunExit;simulation_passed=$taskSimulationPass;passed=($taskCompileExit -eq 0 -and $taskSimulationPass)}
 }
 $taskPassed=@($taskResults | Where-Object {!$_.passed}).Count -eq 0
 # Purpose: bind evidence to exact source bytes, including pre-existing mini
 # baseline and replay seed; changed RTL requires a new run, not a reused log.
 $taskManifest=@($taskSources)+@($taskCases | ForEach-Object {Join-Path $taskFpga "sim/tb_$_.sv"})+@(Join-Path $taskFpga 'rtl/mini_camera_diag/mini_frame_pool.v')+@(Join-Path $taskFpga 'rtl/memory/frame_manager_layout.vh')
 $taskHashes=@($taskManifest | Select-Object -Unique | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
 [ordered]@{passed=$taskPassed;seed=$Seed;cases=$taskResults;sources=$taskHashes;scope='DDR-domain metadata control and modeled drain fences';hardware_tested=$false;native_ddr_verified=$false;programmed=$false} |
  ConvertTo-Json -Depth 6 | Set-Content -LiteralPath result.json -Encoding utf8
 if(!$taskPassed){throw "Frame manager regression/tool run failed; inspect $taskRun/result.json"}
 Write-Output "FRAME_MANAGER_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
