# Purpose: production three-clock RAW8 core with native FIFO models and HMIC
# protocol/memory scoreboard; never opens or modifies any physical device.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_board_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskLib=Join-Path $taskFpga 'build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2'
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOldModelsim=$env:MODELSIM
Push-Location $taskRun
try {
 # Keep native-library mappings and outputs local, leaving installed models intact.
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c
 if($LASTEXITCODE){throw 'vmap init failed'}
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work
 foreach($taskName in @('usim','vsim')){
  & "$ModelSimHome/vmap.exe" $taskName (Join-Path $taskLib $taskName)
  if($LASTEXITCODE){throw 'native mapping failed'}
 }
 $taskSources=@()
 foreach($taskName in @('raw8_word_cdc','raw8_capture_cdc')){
  $taskSources+=Join-Path $taskFpga "ip/$taskName/$taskName.v"
  $taskSources+=Get-ChildItem (Join-Path $taskFpga "ip/$taskName/rtl") -Filter '*.v' | ForEach-Object FullName
 }
 $taskSources+=Get-ChildItem (Join-Path $taskFpga 'rtl/raw8_dual') -Filter '*.v' | ForEach-Object FullName
 $taskSources+=@('rtl/network/praw_packetizer.v','rtl/network/udp_ipv4_eth_tx.v',
  'rtl/network/video_network_tx.v','sim/tb_raw8_board_core.sv') | ForEach-Object {Join-Path $taskFpga $_}
 @($taskSources | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
  ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Board core compilation failed'}
 & "$ModelSimHome/vsim.exe" -c -L usim -L vsim tb_raw8_board_core -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskExit=$LASTEXITCODE
 $taskText=Get-Content simulation.log -Raw
 if($taskExit -or $taskText -notmatch 'RAW8_BOARD_CORE_PASS' -or
    $taskText -match 'RAW8_BOARD_FAIL|RAW8_BOARD_TIMEOUT|\*\* (Fatal|Error)'){throw 'Board core simulation failed'}
 # Independent wire/CRC/host decoder verifies every captured pixel of six frames.
 python -B (Join-Path $taskFpga 'sim/check_raw8_dual.py') $taskRun --board-core | Tee-Object result.json
 if($LASTEXITCODE){throw 'Board host reassembly failed'}
 # First frame retains epoch zero when commissioning races the START record.
 & "$ModelSimHome/vsim.exe" -c -L usim -L vsim tb_raw8_board_core -gLATE_EPOCH=1 -do 'run -all; quit -f' 2>&1 | Tee-Object late_epoch.log
 $taskExit=$LASTEXITCODE;$taskText=Get-Content late_epoch.log -Raw
 if($taskExit -or $taskText -notmatch 'RAW8_BOARD_CORE_PASS' -or
    $taskText -match 'RAW8_BOARD_FAIL|RAW8_BOARD_TIMEOUT|\*\* (Fatal|Error)'){throw 'Late epoch boundary failed'}
 python -B (Join-Path $taskFpga 'sim/check_raw8_dual.py') $taskRun --board-core --late-epoch | Tee-Object late_epoch_result.json
 if($LASTEXITCODE){throw 'Late epoch host identity check failed'}
 Write-Output "RAW8_BOARD_REGRESSION_PASS $taskRun"
} finally {$env:MODELSIM=$taskOldModelsim;Pop-Location}
