# Purpose: native PDS DRM/async-FIFO regression, isolated from board hardware.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_native_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskLib=Join-Path $taskFpga 'build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2'
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOldModelsim=$env:MODELSIM
Push-Location $taskRun
try {
 # Purpose: mapping is local to this run; never edit the simulator installation.
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c
 if($LASTEXITCODE){throw 'vmap init failed'}
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 foreach($taskName in @('usim','vsim')){
  & "$ModelSimHome/vmap.exe" $taskName (Join-Path $taskLib $taskName)
  if($LASTEXITCODE){throw 'native library mapping failed'}
 }
 $taskSources=@()
 foreach($taskName in @('raw8_word_cdc','raw8_capture_cdc')){
  $taskSources+=Join-Path $taskFpga "ip/$taskName/$taskName.v"
  $taskSources+=Get-ChildItem (Join-Path $taskFpga "ip/$taskName/rtl") -Filter '*.v' | ForEach-Object FullName
 }
 $taskSources+=@('rtl/raw8_dual/raw8_native_queue.v','sim/tb_raw8_native_queue.sv') | ForEach-Object {Join-Path $taskFpga $_}
 @($taskSources | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
  ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Native queue compilation failed'}
 foreach($taskWidth in @(256,288)){
  & "$ModelSimHome/vsim.exe" -c -L usim -L vsim tb_raw8_native_queue "-gW=$taskWidth" -do 'run -all; quit -f' 2>&1 | Tee-Object "$taskWidth.log"
  $taskExit=$LASTEXITCODE
  $taskText=Get-Content "$taskWidth.log" -Raw
  if($taskExit -or $taskText -notmatch 'RAW8_NATIVE_QUEUE_PASS' -or
     $taskText -match 'RAW8_FAIL|RAW8_TIMEOUT|\*\* (Fatal|Error)'){throw "Native FIFO failed: $taskWidth"}
 }
 Write-Output "RAW8_NATIVE_REGRESSION_PASS $taskRun"
} finally {$env:MODELSIM=$taskOldModelsim;Pop-Location}
