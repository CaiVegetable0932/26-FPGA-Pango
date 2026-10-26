# Purpose: equal-byte synthetic seven-client mixed load, legal burst caps 4/8/16.
# This benchmarks RTL under an explicit native service model, not board bandwidth.
param([string]$IcarusHome='',[int[]]$Seeds=@(42,1907,20261012))
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app'}
$taskRun=Join-Path $taskFpga ('build/ddr_dma/benchmark_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskMetrics=@()
foreach($taskCap in @(4,8,16)){
 $taskImage=Join-Path $taskRun "cap$taskCap.vvp"
 & "$IcarusHome/bin/iverilog.exe" -g2012 -s tb_ddr_native_dma "-Ptb_ddr_native_dma.BURST_CAP=$taskCap" -o $taskImage (Join-Path $taskFpga 'rtl/memory/ddr_native_dma.v') (Join-Path $taskFpga 'sim/tb_ddr_native_dma.sv') 2>&1 | Tee-Object (Join-Path $taskRun "cap$taskCap.compile.log")
 if($LASTEXITCODE){throw "Profile compile failed: $taskCap"}
 foreach($taskSeed in $Seeds){
  $taskLog=Join-Path $taskRun "cap$taskCap.$taskSeed.log"
  & "$IcarusHome/bin/vvp.exe" $taskImage "+seed=$taskSeed" 2>&1 | Tee-Object $taskLog
  $taskText=Get-Content -LiteralPath $taskLog -Raw
  if($LASTEXITCODE -ne 0 -or $taskText -notmatch 'DDR_DMA_PASS' -or $taskText -match 'FATAL|TIMEOUT'){throw "Profile failed: $taskLog"}
  $taskMatch=[regex]::Match($taskText,'DDR_MIXED_METRIC burst_cap=(\d+) cycles=(\d+) bus_bytes=(\d+)')
  if(!$taskMatch.Success -or [int]$taskMatch.Groups[3].Value -ne 88320){throw 'Equal-byte mixed workload not satisfied'}
  $taskWait=@([regex]::Matches($taskText,'DDR_MIXED_CLIENT client=(\d+) max_wait_cycles=(\d+)') | ForEach-Object {
   @{client=[int]$_.Groups[1].Value;max_wait_cycles=[int]$_.Groups[2].Value}
  })
  $taskCycles=[int]$taskMatch.Groups[2].Value
  $taskMetrics+=@{burst_cap=$taskCap;seed=$taskSeed;clock_period_ns=8;mixed_cycles=$taskCycles;bus_bytes=88320;useful_bytes=88320;model_MBps=88320/($taskCycles*8e-9)/1e6;client_wait=$taskWait;log=$taskLog}
 }
}
# Purpose: preserve the existing frame ownership regression after completion changes.
$taskPool=Join-Path $taskRun 'pool.vvp'
& "$IcarusHome/bin/iverilog.exe" -g2012 -s tb_mini_frame_pool -o $taskPool (Join-Path $taskFpga 'rtl/mini_camera_diag/mini_frame_pool.v') (Join-Path $taskFpga 'sim/tb_mini_frame_pool.sv')
if($LASTEXITCODE){throw 'Frame pool compile failed'}
& "$IcarusHome/bin/vvp.exe" $taskPool 2>&1 | Tee-Object (Join-Path $taskRun 'pool.log')
if($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $taskRun 'pool.log') -Raw) -notmatch 'FRAME_POOL_PASS'){throw 'Frame pool regression failed'}
# Purpose: specifically regress the removed watchdog's ownership corruption.
$taskArbiter=Join-Path $taskRun 'arbiter.vvp'
& "$IcarusHome/bin/iverilog.exe" -g2012 -s tb_dma_arbiter_drain -o $taskArbiter (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/mem_read_arbi.v') (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/mem_write_arbi.v') (Join-Path $taskFpga 'sim/tb_dma_arbiter_drain.sv')
if($LASTEXITCODE){throw 'Arbiter drain compile failed'}
& "$IcarusHome/bin/vvp.exe" $taskArbiter 2>&1 | Tee-Object (Join-Path $taskRun 'arbiter.log')
if($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $taskRun 'arbiter.log') -Raw) -notmatch 'DMA_ARBITER_DRAIN_PASS'){throw 'Arbiter ownership regression failed'}
$taskHashes=@('rtl/memory/ddr_native_dma.v','sim/tb_ddr_native_dma.sv','rtl/mini_camera_diag/mini_frame_pool.v','sim/tb_mini_frame_pool.sv' | ForEach-Object {Get-FileHash (Join-Path $taskFpga $_) -Algorithm SHA256 | Select-Object Path,Hash})
[ordered]@{passed=$true;model_only=$true;hardware_tested=$false;assumptions='125 MHz; finite random AW/AR/W/R gaps; 12/97-cycle address pause; one native transaction; random finite sinks; full beat payload in mixed phase';sources=$taskHashes;metrics=$taskMetrics} |
 ConvertTo-Json -Depth 7 | Set-Content (Join-Path $taskRun 'benchmark.json') -Encoding utf8
Write-Output "DDR_DMA_BENCHMARK_PASS $taskRun"
