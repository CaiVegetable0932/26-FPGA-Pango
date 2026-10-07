# Purpose: compile and run the isolated geometry datapath/control regression.
# This never opens JTAG, changes the stable board top, or writes official docs.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@(Get-ChildItem (Join-Path $taskFpga 'rtl/geometry') -Filter '*.v' | ForEach-Object FullName)
$taskSources+=Join-Path $taskFpga 'sim/tb_geometry.sv'
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'geometry vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw "geometry compile failed: $taskRun"}
 & "$ModelSimHome/vsim.exe" -c tb_geometry -do 'run -all; quit -f' 2>&1 | Tee-Object test.log
 if($LASTEXITCODE -or (Get-Content test.log -Raw) -notmatch 'GEOMETRY_PASS' -or
    (Get-Content test.log -Raw) -match '\*\* (Fatal|Error)'){
  throw "geometry simulation failed: $taskRun"
 }
 # Purpose: independently compare fixed-point map quantization against the
 # analytic lens/rotation model; keep PC code out of the live video path.
 python -B (Join-Path $taskFpga 'sim/test_geometry_reference.py') 2>&1 | Tee-Object reference.log
 if($LASTEXITCODE -or (Get-Content reference.log -Raw) -notmatch 'GEOMETRY_REFERENCE_PASS'){
  throw "geometry reference check failed: $taskRun"
 }
 Write-Output "GEOMETRY_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
