# Purpose: reproducible offline native DDR/DMA scoreboards; no JTAG or IP edits.
param(
 [ValidateSet('ModelSim','Icarus')][string]$Simulator='Icarus',
 [string]$ModelSimHome='E:/ModelsimSE/win64',
 [string]$IcarusHome='',
 [int[]]$Seeds=@(42,1907,20261012)
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app'}
$taskIverilog=Join-Path $IcarusHome 'bin/iverilog.exe'
$taskVvp=Join-Path $IcarusHome 'bin/vvp.exe'
if(!(Test-Path -LiteralPath $taskIverilog)){throw "Icarus runtime missing: $taskIverilog"}
$taskRun=Join-Path $taskFpga ('build/ddr_dma/'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
if($Simulator -eq 'ModelSim'){
 Push-Location $taskRun
 try { & "$ModelSimHome/vlib.exe" work; if($LASTEXITCODE){throw 'vlib failed'} } finally {Pop-Location}
}
$taskSources=@(
 (Join-Path $taskFpga 'rtl/memory/ddr_native_dma.v'),
 (Join-Path $taskFpga 'rtl/memory/dma_pixel_pack.v'),
 (Join-Path $taskFpga 'rtl/memory/dma_byte_unpack.v'),
 (Join-Path $taskFpga 'rtl/memory/dma_row_plan.v')
)
$taskResults=@()
foreach($taskBench in @('tb_ddr_native_dma','tb_dma_bytes','tb_dma_bytes_aligned','tb_mini_ddr_native_bridge','tb_frame_dma_tail','tb_axi_master_dma','tb_dma_arbiter_drain','tb_raw_ddr_adapter')){
 # The independent byte scoreboard covers generic offsets and the board's
 # aligned rows separately, including partial tails and random backpressure.
 $taskAligned=$taskBench -eq 'tb_dma_bytes_aligned'
 $taskTop=if($taskAligned){'tb_dma_bytes'}else{$taskBench}
 $taskTb=Join-Path $taskFpga "sim/$taskTop.sv"
 if(!(Test-Path -LiteralPath $taskTb)){throw "Required regression missing: $taskTb"}
 $taskImage=Join-Path $taskRun "$taskBench.vvp"
 $taskExtra=@(
  (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/mini_ddr_native_bridge.v'),
  (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/frame_fifo_write.v'),
  (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/frame_fifo_read.v'),
  (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/aq_axi_master_256.v'),
  (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/mem_read_arbi.v'),
  (Join-Path $taskFpga 'rtl/mini_camera_diag/vendor/frame_ddr3/mem_write_arbi.v'),
  (Join-Path $taskFpga 'rtl/network/raw_dma_reader.sv')
 )
 if($Simulator -eq 'ModelSim'){
  & "$ModelSimHome/vlog.exe" -sv -work (Join-Path $taskRun 'work') @taskSources @taskExtra $taskTb 2>&1 | Tee-Object (Join-Path $taskRun "$taskBench.compile.log")
 } else {
  [string[]]$taskParameterArgs=if($taskAligned){@('-Ptb_dma_bytes.ALIGNED_ROWS=1')}else{@()}
  & $taskIverilog -g2012 -s $taskTop @taskParameterArgs -o $taskImage @taskSources @taskExtra $taskTb 2>&1 | Tee-Object (Join-Path $taskRun "$taskBench.compile.log")
 }
 if($LASTEXITCODE){throw "Compile failed: $taskBench"}
 foreach($taskSeed in $Seeds){
  $taskLog=Join-Path $taskRun "$taskBench.$taskSeed.log"
  if($Simulator -eq 'ModelSim'){
   Push-Location $taskRun
   [string[]]$taskParameterArgs=if($taskAligned){@('-gALIGNED_ROWS=1')}else{@()}
   try { & "$ModelSimHome/vsim.exe" -c -lib ./work $taskTop @taskParameterArgs "+seed=$taskSeed" -do 'onerror {quit -code 2}; run -all; quit -f' 2>&1 | Tee-Object $taskLog } finally {Pop-Location}
  } else { & $taskVvp $taskImage "+seed=$taskSeed" 2>&1 | Tee-Object $taskLog }
  $taskExit=$LASTEXITCODE
  $taskText=Get-Content -LiteralPath $taskLog -Raw
  $taskPass=$taskExit -eq 0 -and $taskText -match '_PASS' -and $taskText -notmatch 'FATAL|ERROR|TIMEOUT'
  $taskResults+=@{bench=$taskBench;seed=$taskSeed;passed=$taskPass;native_exit=$taskExit;log=$taskLog}
  if(!$taskPass){$taskResults | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $taskRun 'results.json');throw "Regression failed: $taskLog"}
 }
}
# Purpose: archive source identities together with actual results, not estimates.
$taskAllSources=@($taskSources)+@($taskExtra)+@(Get-ChildItem (Join-Path $taskFpga 'sim') -Filter 'tb*ddr*.sv' | Select-Object -ExpandProperty FullName)+@(
 (Join-Path $taskFpga 'sim/tb_dma_bytes.sv'),(Join-Path $taskFpga 'sim/tb_frame_dma_tail.sv'),
 (Join-Path $taskFpga 'sim/tb_axi_master_dma.sv'),(Join-Path $taskFpga 'sim/tb_dma_arbiter_drain.sv')
)
$taskHashes=@($taskAllSources | Sort-Object -Unique | ForEach-Object {Get-FileHash -LiteralPath $_ -Algorithm SHA256 | Select-Object Path,Hash})
[ordered]@{passed=$true;hardware_tested=$false;pnr_tested=$false;simulator=$Simulator;sources=$taskHashes;results=$taskResults} |
 ConvertTo-Json -Depth 6 | Set-Content (Join-Path $taskRun 'results.json') -Encoding utf8
Write-Output "DDR_DMA_REGRESSION_PASS $taskRun"
