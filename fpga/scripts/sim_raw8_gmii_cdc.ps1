# Purpose: verify independent-clock packet preservation with installed native
# FIFO models. This does not access network/UART/JTAG or change a board image.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_gmii_cdc_'+(Get-Date -Format yyyyMMdd_HHmmss_fff))
$taskInputs=@((Join-Path $taskFpga 'ip/raw8_capture_cdc/raw8_capture_cdc.v'))+
 @(Get-ChildItem (Join-Path $taskFpga 'ip/raw8_capture_cdc/rtl') -Filter '*.v' | ForEach-Object FullName)+
 @('rtl/raw8_dual/raw8_native_queue.v','rtl/raw8_dual/raw8_gmii_cdc.v','sim/tb_raw8_gmii_cdc.sv'|ForEach-Object {Join-Path $taskFpga $_})
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOld=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c
 if($LASTEXITCODE){throw 'local mapping failed'}
 $env:MODELSIM=Join-Path $taskRun modelsim.ini
 & "$ModelSimHome/vlib.exe" work
 foreach($taskLib in @('usim','vsim')){
  & "$ModelSimHome/vmap.exe" $taskLib (Join-Path $taskFpga "build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2/$taskLib")
  if($LASTEXITCODE){throw 'native mapping failed'}
 }
 & "$ModelSimHome/vlog.exe" -sv @taskInputs 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'bridge compilation failed'}
 foreach($taskHalf in @('3.9','4.1')){
  $taskLog="half_$taskHalf.log"
  & "$ModelSimHome/vsim.exe" -c -L usim -L vsim tb_raw8_gmii_cdc "-gRD_HALF=$taskHalf" -do 'run -all; quit -f' 2>&1 | Tee-Object $taskLog
  if($LASTEXITCODE -or !(Select-String $taskLog -Pattern RAW8_GMII_CDC_PASS -Quiet) -or
     (Select-String $taskLog -Pattern '\*\* (Fatal|Error)|RAW8_GMII_CDC_FAIL|RAW8_GMII_CDC_TIMEOUT' -Quiet)){throw 'native bridge regression failed'}
 }
 [ordered]@{passed=$true;packets_per_case=81;read_half_period_ns=@(3.9,4.1);
  native_fifo_models=$true;hardware_tested=$false;
  sources=@($taskInputs|ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}})} |
  ConvertTo-Json -Depth 4 | Set-Content result.json -Encoding utf8
 Write-Output "RAW8_GMII_CDC_NATIVE_PASS $taskRun"
} finally {$env:MODELSIM=$taskOld;Pop-Location}
