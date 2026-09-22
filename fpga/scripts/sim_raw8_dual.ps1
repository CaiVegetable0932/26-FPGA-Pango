# Purpose: isolated, reproducible RAW8 RTL regression using installed ModelSim.
# It does not open UART/JTAG/network devices or alter the proven board images.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_dual_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@(Get-ChildItem (Join-Path $taskFpga 'rtl/raw8_dual') -Filter '*.v' | ForEach-Object FullName)
$taskSources+=@('rtl/mini_camera_diag/ov5640_sccb.v',
 'rtl/mini_camera_diag/vendor/camera/data_init.v','sim/tb_ov5640_verified_startup.sv',
 'sim/tb_raw8_capture.sv','sim/tb_raw8_startup.sv','sim/tb_raw8_pool.sv',
 'sim/tb_raw8_read_scheduler.sv','sim/tb_raw8_dual_pixels.sv',
 'rtl/network/praw_packetizer.v','rtl/network/udp_ipv4_eth_tx.v',
 'rtl/network/video_network_tx.v') | ForEach-Object {Join-Path $taskFpga $_}
# Purpose: record the exact tested source set and make failures visible even
# when a simulator returns zero after a Verilog fatal assertion.
@($taskSources+@($PSCommandPath,(Join-Path $taskFpga 'sim/check_raw8_dual.py'),
 (Join-Path $taskFpga '../host/src/pango_video/protocol.py'),
 (Join-Path $taskFpga '../host/src/pango_video/reassembly.py')) | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
}) | ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'RAW8 compile failed'}
 # Purpose: component faults precede full-frame concurrent-output simulation.
 foreach($taskCase in @('capture_small','capture_1080','startup','pool','read_scheduler','dual_pixels')){
  $taskTop=if($taskCase.StartsWith('capture_')){'tb_raw8_capture'}else{"tb_raw8_$taskCase"}
  $taskArgs=@('-c',$taskTop,'-do','run -all; quit -f')
  if($taskCase -eq 'capture_1080'){$taskArgs+=@('-gW=1920','-gH=1080')}
  & "$ModelSimHome/vsim.exe" @taskArgs 2>&1 | Tee-Object "$taskCase.log"
  $taskExit=$LASTEXITCODE
  $taskText=Get-Content "$taskCase.log" -Raw
  if($taskExit -or $taskText -match 'RAW8_FAIL|RAW8_TIMEOUT|MODEL_FAIL|\*\* (Fatal|Error)' -or
     $taskText -notmatch 'RAW8_\w+_PASS'){throw "RAW8 case failed: $taskCase; $taskRun"}
 }
 # Purpose: decode actual simulated wire bytes through the production host,
 # separately from the RTL scoreboard and without opening a network socket.
 python -B (Join-Path $taskFpga 'sim/check_raw8_dual.py') $taskRun | Tee-Object result.json
 if($LASTEXITCODE){throw 'RAW8 host reassembly failed'}
 Write-Output "RAW8_DUAL_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
