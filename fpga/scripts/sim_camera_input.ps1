# 用途：02输入分区专用离线回归，不修改共享工程、原生IP或调用下载工具。
param([string]$IcarusHome='', [switch]$SkipFullFrame,
 [ValidateSet('dvp_frame_receiver','dvp_rgb565_receiver','dvp_frame_warmup','dvp_raw8_fanout',
 'dvp_raw8_queues','dvp_clock_watchdog','ov5640_register_service','ov5640_service_deadline',
 'ov5640_raw8_mode','dvp_raw8_full')][string[]]$Cases=@())
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'}
$taskRun=Join-Path $taskFpga ('build/camera_input_20261012/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Force $taskRun | Out-Null
$taskNames=@('dvp_frame_receiver','dvp_rgb565_receiver','dvp_frame_warmup','dvp_raw8_fanout','dvp_raw8_queues','dvp_clock_watchdog','ov5640_register_service','ov5640_service_deadline','ov5640_raw8_mode')
if(!$SkipFullFrame){$taskNames+='dvp_raw8_full'}
# 用途：只重跑受影响的用例，避免对已通过且源码未变的全尺寸测试反复执行。
if($Cases.Count){$taskNames=$Cases}
$taskSources=@('rtl/input/dvp_frame_receiver.v','rtl/input/dvp_raw8_fanout.v','rtl/input/dvp_clock_watchdog.v','rtl/input/ov5640_register_service.v','rtl/input/ov5640_raw8_mode.v','rtl/mini_camera_diag/vendor/camera/SCCB.v','sim/ov5640_sccb_model.sv') | ForEach-Object {Join-Path $taskFpga $_}
$taskSources+=@($taskNames | ForEach-Object {Join-Path $taskFpga "sim/tb_$_.sv"})
# 用途：保存本次源码/TB快照，后续并发修改不会被旧日志冒充为已验证。
$taskSourceHashes=@($taskSources | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash} })
$taskSourceHashes | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $taskRun 'source_hashes.json') -Encoding UTF8
Push-Location $taskRun
try {
 $taskResults=[ordered]@{}
 foreach($taskCase in $taskNames){
  & "$IcarusHome/iverilog.exe" -g2012 -s "tb_$taskCase" -o "$taskCase.vvp" @taskSources 2>&1 | Tee-Object "$taskCase.compile.log"
  if($LASTEXITCODE -ne 0){throw "Input compile failed: $taskCase"}
  & "$IcarusHome/vvp.exe" "$taskCase.vvp" 2>&1 | Tee-Object "$taskCase.log"
  $taskExit=$LASTEXITCODE;$taskLog=Get-Content "$taskCase.log" -Raw
  $taskPassed=$taskExit -eq 0 -and $taskLog -match ($taskCase.ToUpper()+'_PASS') -and $taskLog -notmatch 'FATAL|_FAIL|_TIMEOUT'
  $taskResults[$taskCase]=$taskPassed
  if(!$taskPassed){throw "Input regression failed: $taskCase at $taskRun"}
 }
 [ordered]@{passed=$true;run=$taskRun;cases=$taskResults;full_frame_tested=($taskNames -contains 'dvp_raw8_full');hardware_verified=$false;board_integrated=$false} | ConvertTo-Json -Depth 4 | Set-Content result.json -Encoding UTF8
 Write-Output "CAMERA_INPUT_OFFLINE_PASS $taskRun"
}finally{Pop-Location}
