# Purpose: full native-FIFO board-core regression, with no physical I/O.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_board_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskLib=Join-Path $taskFpga 'build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2'
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOldModelsim=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 foreach($taskName in @('usim','vsim')){
  & "$ModelSimHome/vmap.exe" $taskName (Join-Path $taskLib $taskName) | Out-Null
  if($LASTEXITCODE){throw 'native mapping failed'}
 }
 $taskSources=@()
 foreach($taskName in @('raw8_word_cdc','raw8_capture_cdc')){
  $taskSources+=Join-Path $taskFpga "ip/$taskName/$taskName.v"
  $taskSources+=Get-ChildItem (Join-Path $taskFpga "ip/$taskName/rtl") -Filter '*.v' | ForEach-Object FullName
 }
 foreach($taskName in @('geometry','raw8_dual')){
  $taskSources+=Get-ChildItem (Join-Path $taskFpga "rtl/$taskName") -Filter '*.v' | ForEach-Object FullName
 }
 $taskSources+=@('rtl/network/praw_packetizer.v','rtl/network/udp_ipv4_eth_tx.v',
  'rtl/network/video_network_tx.v','sim/tb_geometry_board_core.sv') | ForEach-Object {Join-Path $taskFpga $_}
 @($taskSources | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
  ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'geometry board compile failed'}
 & "$ModelSimHome/vsim.exe" -c -L usim -L vsim tb_geometry_board_core -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskText=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'GEOMETRY_BOARD_PASS' -or
    $taskText -match 'GEOMETRY_BOARD_FAIL|GEOMETRY_BOARD_TIMEOUT|\*\* (Fatal|Error)'){throw 'geometry board simulation failed'}
 Write-Output "GEOMETRY_BOARD_REGRESSION_PASS $taskRun"
} finally {$env:MODELSIM=$taskOldModelsim;Pop-Location}
