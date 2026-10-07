# Purpose: isolated real-UART -> frozen core control-path test. No RTL writes,
# PDS, constraints changes or hardware. Native FIFO libraries are reused read-
# only. Hash all compiled inputs and all constraints before and after even fail.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_core_read_uart_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskLib=Join-Path $taskFpga 'build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2'
$taskSources=@()
foreach($taskName in @('raw8_word_cdc','raw8_capture_cdc')){
 $taskSources+=Join-Path $taskFpga "ip/$taskName/$taskName.v"
 $taskSources+=Get-ChildItem (Join-Path $taskFpga "ip/$taskName/rtl") -Filter '*.v' | ForEach-Object FullName
}
foreach($taskName in @('geometry','raw8_dual')){
 $taskSources+=Get-ChildItem (Join-Path $taskFpga "rtl/$taskName") -Filter '*.v' | ForEach-Object FullName
}
$taskSources+=@('rtl/control/mcu_protocol.v','rtl/control/mcu_frame_rx.v','rtl/control/mcu_frame_tx.v',
 'rtl/control/mcu_uart_rx.v','rtl/control/mcu_uart_tx.v','rtl/network/praw_packetizer.v',
 'rtl/network/udp_ipv4_eth_tx.v','rtl/network/video_network_tx.v','sim/tb_geometry_core_read_uart.sv') | ForEach-Object {Join-Path $taskFpga $_}
$taskInputs=@($taskSources)+@($PSCommandPath)+@(Get-ChildItem (Join-Path $taskFpga 'constraints') -Recurse -File | ForEach-Object FullName)
$taskInputs=@($taskInputs | Sort-Object -Unique)
$taskBefore=@($taskInputs | ForEach-Object {[pscustomobject][ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
$taskBefore | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $taskRun 'sources.before.json') -Encoding utf8
$taskOld=$env:MODELSIM;$taskPassed=$false;$taskCases=@()
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 if($LASTEXITCODE){throw 'UART vmap failed'}
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'UART vlib failed'}
 foreach($taskName in @('usim','vsim')){
  & "$ModelSimHome/vmap.exe" $taskName (Join-Path $taskLib $taskName) | Out-Null
  if($LASTEXITCODE){throw 'Native library mapping failed'}
 }
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'UART core compile failed'}
 # 125MHz throughout. Accelerated serial traffic covers every marker word;
 # the second case uses actual production 115200 baud (not byte injection).
 foreach($taskCase in @(@{baud=7812500;smoke=0;log='uart_125mhz_fast.log'},@{baud=115200;smoke=1;log='uart_125mhz_115200.log'})){
  & "$ModelSimHome/vsim.exe" -c -L usim -L vsim tb_geometry_core_read_uart '-gCLK_HZ=125000000' "-gBAUD=$($taskCase.baud)" "-gSMOKE=$($taskCase.smoke)" -do 'run -all; quit -f' 2>&1 | Tee-Object $taskCase.log
  $taskText=Get-Content $taskCase.log -Raw
  $taskOk=($LASTEXITCODE -eq 0 -and $taskText -match 'CORE_READ_UART_PASS' -and $taskText -notmatch 'CORE_READ_UART_(FAIL|TIMEOUT)|\*\* (Fatal|Error)')
  $taskCases+=[ordered]@{baud=$taskCase.baud;smoke=$taskCase.smoke;log=$taskCase.log;passed=$taskOk}
  if(!$taskOk){throw "Core UART failed: $($taskCase.log); $taskRun"}
 }
 $taskPassed=$true
} finally {
 $taskAfter=@(foreach($taskEntry in $taskBefore){
  $taskHash=(Get-FileHash -LiteralPath $taskEntry.path).Hash
  [ordered]@{path=$taskEntry.path;before_sha256=$taskEntry.sha256;after_sha256=$taskHash;unchanged=($taskHash -eq $taskEntry.sha256)}
 })
 $taskUnchanged=@($taskAfter | Where-Object {-not $_.unchanged}).Count -eq 0
 $taskAfter | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $taskRun 'sources.verification.json') -Encoding utf8
 [ordered]@{passed=($taskPassed -and $taskUnchanged);source_inputs_unchanged=$taskUnchanged;clock_hz=125000000;
  cases=$taskCases;control_path_only=$true;static_status_snapshot_forced=$true;pixel_integration_tested=$false;
  timing_verified=$false;pds_run=$false;hardware_tested=$false} | ConvertTo-Json -Depth 5 |
  Set-Content (Join-Path $taskRun 'result.json') -Encoding utf8
 $env:MODELSIM=$taskOld;Pop-Location
 if(!$taskUnchanged){throw "Input hash drift: $taskRun"}
}
Write-Output "CORE_READ_UART_REGRESSION_PASS $taskRun"
