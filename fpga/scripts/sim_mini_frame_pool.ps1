# Purpose: run the frame-pool ownership regression without DDR hardware or JTAG.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mini_camera_diag/pool_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv -work work (Join-Path $taskFpga 'rtl/mini_camera_diag/mini_frame_pool.v') (Join-Path $taskFpga 'sim/tb_mini_frame_pool.sv') 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'vlog failed'}
 & "$ModelSimHome/vsim.exe" -c -lib ./work tb_mini_frame_pool -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskExit=$LASTEXITCODE
 $taskText=Get-Content simulation.log -Raw
 $taskPassed=$taskExit -eq 0 -and $taskText -match 'FRAME_POOL_PASS' -and $taskText -notmatch 'FRAME_POOL_FAIL|FRAME_POOL_TIMEOUT'
 [ordered]@{passed=$taskPassed;native_exit=$taskExit;scope='slot ownership only';hardware_tested=$false} | ConvertTo-Json | Set-Content result.json
 if(!$taskPassed){throw 'Frame pool regression failed'}
 Write-Output "FRAME_POOL_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
