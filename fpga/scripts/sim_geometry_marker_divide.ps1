# Purpose: immutable-original cycle miter and independent arithmetic oracle.
# The candidate RTL is read-only during testing; all generated files stay in
# a unique FPGA build directory. No board, vendor or shared script is changed.
param([string]$ModelSimHome='E:/ModelsimSE/win64',[int[]]$Seeds=@(20261007,1,987654321))
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/marker_divider_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskReference=Join-Path $taskFpga 'sim/candidates/geometry_marker_divide_reference_20261007.v'
if((Get-FileHash $taskReference).Hash -ne '44D7CC0F7BDD4B4977DAB67BAB0AEEE73E494391BCBE53FD93159DDCACB0A8B5'){throw 'Original divider reference changed'}
$taskCandidate=Join-Path $taskFpga 'rtl/geometry/geometry_marker_divide.v'
$taskBench=Join-Path $taskFpga 'sim/tb_geometry_marker_divide.sv'
# Only mechanically rename the original module in a generated build fixture.
$taskGolden=Join-Path $taskRun 'geometry_marker_divide_reference.v'
$taskText=[IO.File]::ReadAllText($taskReference).Replace('module geometry_marker_divide(','module geometry_marker_divide_reference(')
[IO.File]::WriteAllText($taskGolden,$taskText,[Text.UTF8Encoding]::new($false))
$taskManifest=@(@($taskReference,$taskCandidate,$taskBench,$PSCommandPath) | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}})
$taskManifest | ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
$taskOld=$env:MODELSIM;$taskPassed=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 if($LASTEXITCODE){throw 'vmap failed'}
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv $taskGolden $taskCandidate $taskBench 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'divider compile failed'}
 foreach($taskSeed in $Seeds){
  & "$ModelSimHome/vsim.exe" -c tb_geometry_marker_divide "+SEED=$taskSeed" -do 'run -all; quit -f' 2>&1 | Tee-Object "seed_$taskSeed.log"
  $taskText=Get-Content "seed_$taskSeed.log" -Raw
  if($LASTEXITCODE -or $taskText -notmatch 'MARKER_DIVIDER_PASS' -or $taskText -match 'DIVIDER_.*(FAIL|TIMEOUT)|\*\* (Fatal|Error)'){throw "Divider seed $taskSeed failed"}
 }
 foreach($taskEntry in $taskManifest){if((Get-FileHash $taskEntry.path).Hash -ne $taskEntry.sha256){throw 'Divider test input drift'}}
 $taskPassed=$true
} finally {
 [ordered]@{passed=$taskPassed;seeds=$Seeds;nonzero_latency_cycles=96;zero_latency_cycles=0;formal_proof=$false;hardware_tested=$false} | ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOld;Pop-Location
}
Write-Output "MARKER_DIVIDER_REGRESSION_PASS $taskRun"
