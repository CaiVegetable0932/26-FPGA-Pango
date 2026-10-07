# Purpose: standalone cycle-exact reply-queue test for production RTL, the
# exploratory prototype, or a native netlist. This is not a board-top test.
# No native board inputs are changed; all simulator outputs stay in fpga/build.
param([string]$ModelSimHome='E:/ModelsimSE/win64',[string]$NativeNetlist='',
 [string]$RtlSource='')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mcu_reply_queue_ram_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@('sim/candidates/mcu_reply_queue_ram.v','sim/tb_mcu_reply_queue_ram.sv') |
 ForEach-Object {Join-Path $taskFpga $_}
# Purpose: the same independent oracle may verify the PDS-generated netlist,
# including vendor block-RAM collision behavior, without compiling RTL twice.
if($NativeNetlist){$taskSources[0]=(Resolve-Path -LiteralPath $NativeNetlist).Path}
# Purpose: verify the private helper bundled in the production protocol source
# with the same queue oracle, without depending on the experimental copy.
if($RtlSource){
 if($NativeNetlist){throw 'Choose either RTL or netlist, not both'}
 $taskSources[0]=(Resolve-Path -LiteralPath $RtlSource).Path
}
$taskOldModelsim=$env:MODELSIM;$taskPassed=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'vlib failed'}
 if($NativeNetlist){
  foreach($taskName in @('usim','vsim')){
   & "$ModelSimHome/vmap.exe" $taskName (Join-Path $taskFpga "build/simlib_2022_2_sp6_4_modelsim_10_1c_logos2/$taskName") | Out-Null
   if($LASTEXITCODE){throw 'Native library mapping failed'}
  }
 }
 @($taskSources+@($PSCommandPath) | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
  ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Queue compilation failed'}
 $taskLibArgs=@();if($NativeNetlist){$taskLibArgs=@('-L','usim','-L','vsim')}
 & "$ModelSimHome/vsim.exe" -c @taskLibArgs tb_mcu_reply_queue_ram -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskText=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'QUEUE_RAM_EQUIVALENCE_PASS' -or
  $taskText -match '\*\* (Fatal|Error)|QUEUE_RAM_(FAIL|TIMEOUT|MISSING)'){throw 'Queue comparison failed'}
 foreach($taskEntry in (Get-Content sources.json -Raw | ConvertFrom-Json)){
  if((Get-FileHash $taskEntry.path).Hash -ne $taskEntry.sha256){throw 'Input changed during test'}
 }
 $taskPassed=$true
} finally {
 [ordered]@{equivalence_passed=$taskPassed;native_netlist=[bool]$NativeNetlist;
  selected_source=$taskSources[0];board_top_simulated=$false;hardware_tested=$false} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
Write-Output "MCU_REPLY_QUEUE_RAM_PASS $taskRun"
