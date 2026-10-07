# Purpose: isolated ModelSim pipeline/FSM equivalence and sustained issue test.
# Generates only FPGA-local vectors/logs; never opens physical board interfaces.
param([string]$ModelSimHome='E:/ModelsimSE/win64',
 [string]$Python='C:/Users/ROG/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/map_stream_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOld=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 & $Python -B (Join-Path $taskFpga 'sim/prepare_geometry_vectors.py') $taskRun
 if($LASTEXITCODE){throw 'reference preparation failed'}
 $taskSources=@('rtl/geometry/geometry_mul_pipe.v','rtl/geometry/geometry_lens_lut.v',
 'rtl/geometry/geometry_map_engine.v','rtl/geometry/geometry_map_stream.v',
 'sim/tb_geometry_map_stream.sv') | ForEach-Object {Join-Path $taskFpga $_}
 @($taskSources | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
 ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'stream compile failed'}
 foreach($taskModel in @(0,1,2)){
  & "$ModelSimHome/vsim.exe" -c tb_geometry_map_stream "-gKIND=$taskModel" -do 'run -all; quit -f' 2>&1 | Tee-Object "model$taskModel.log"
  $taskText=Get-Content "model$taskModel.log" -Raw
  if($LASTEXITCODE -or $taskText -notmatch 'MAP_STREAM_PASS' -or $taskText -match 'FAIL|TIMEOUT|\*\* (Fatal|Error)'){throw "stream model $taskModel failed"}
 }
 Write-Output "MAP_STREAM_REGRESSION_PASS $taskRun"
} finally {$env:MODELSIM=$taskOld;Pop-Location}

