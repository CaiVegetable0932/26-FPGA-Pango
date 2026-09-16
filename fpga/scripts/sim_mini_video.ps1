# Purpose: full-frame raster and TMDS roundtrip regression; no hardware access.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mini_camera_diag/video_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@('rtl/mini_camera_diag/vendor/sync_vg.v','rtl/mini_camera_diag/vendor/timing_gen_xy.v',
 'rtl/mini_camera_diag/vendor/video_rect_read_data.v','rtl/mini_camera_diag/vendor/hdmi/tmds_encoder.v','sim/tb_mini_video.sv') |
 ForEach-Object {Join-Path $taskFpga $_}
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv -work work @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'vlog failed'}
 & "$ModelSimHome/vsim.exe" -c -lib ./work tb_mini_video -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskExit=$LASTEXITCODE
 $taskText=Get-Content simulation.log -Raw
 $taskPassed=$taskExit -eq 0 -and $taskText -match 'VIDEO_PASS' -and $taskText -notmatch 'VIDEO_FAIL|VIDEO_TIMEOUT'
 [ordered]@{passed=$taskPassed;native_exit=$taskExit;scope='raster, one-cycle FIFO model and TMDS encoder';hardware_tested=$false} |
 ConvertTo-Json | Set-Content result.json
 if(!$taskPassed){throw 'Video regression failed'}
 Write-Output "VIDEO_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
