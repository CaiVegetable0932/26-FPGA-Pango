# Purpose: native-interface writer simulation only, no hardware access.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/stream_writer_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOld=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 $taskSources=@('rtl/geometry/geometry_result_stream_writer.v','sim/tb_geometry_stream_writer.sv') | ForEach-Object {Join-Path $taskFpga $_}
 @($taskSources | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) | ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'writer compile failed'}
 foreach($taskBad in @(0,1)){
  & "$ModelSimHome/vsim.exe" -c tb_geometry_stream_writer "-gBAD_FENCE=$taskBad" -do 'run -all; quit -f' 2>&1 | Tee-Object "case$taskBad.log"
  $taskText=Get-Content "case$taskBad.log" -Raw
  if($LASTEXITCODE -or $taskText -notmatch 'STREAM_WRITER(_BAD_FENCE)?_PASS' -or $taskText -match 'FAIL|TIMEOUT|\*\* (Fatal|Error)'){throw 'stream writer failed'}
 }
 Write-Output "STREAM_WRITER_REGRESSION_PASS $taskRun"
} finally {$env:MODELSIM=$taskOld;Pop-Location}

