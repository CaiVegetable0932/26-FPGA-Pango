# Purpose: reproducible offline board-adapter regressions; no physical I/O.
# Official models are read-only inputs, and all tool output stays under fpga.
param([string]$ModelSimHome='E:/ModelsimSE/win64',
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [ValidateSet('phy','pll','boot','source')][string]$Case='phy',
 [ValidateSet(0,1)][int]$PhyTxDelay=1)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/comms_board_sim/'+$Case+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskSources=@('rtl/network/mdio_clause22.v','rtl/network/rtl8211f_init.v')
$taskTop='tb_rtl8211f_init';$taskMarker='PHY_INIT_PASS'
if($Case -eq 'pll'){$taskSources=@('ip/comms_pll/comms_pll.v');$taskTop='tb_comms_pll';$taskMarker='COMMS_PLL_PASS'}
if($Case -eq 'boot'){
 $taskSources+=@(Get-ChildItem (Join-Path $taskFpga 'rtl/control') -Filter 'mcu_*.v' | ForEach-Object {$_.FullName})
 $taskSources+=@('rtl/control/comms_boot_config.v')
 $taskTop='tb_comms_boot_config';$taskMarker='COMMS_BOOT_PASS'
}
if($Case -eq 'source'){
 $taskSources=@('rtl/network/praw_packetizer.v',
 'rtl/network/udp_ipv4_eth_tx.v','rtl/network/video_network_tx.v',
 'rtl/network/pango_rgmii_tx.v','rtl/network/comms_test_source.v')
 $taskTop='tb_comms_test_source';$taskMarker='COMMS_SOURCE_PASS'
}
$taskSources+=@('sim/'+$taskTop+'.sv')
$taskSources=@($taskSources | ForEach-Object {if([IO.Path]::IsPathRooted($_)){$_}else{Join-Path $taskFpga $_}})
$taskModels=@()
if($Case -in @('pll','source')){
 $taskModelNames=@('GTP_GRS.v','GTP_ODDR_E1.v')
 if($Case -eq 'pll'){$taskModelNames+=@('GTP_GPLL.v')}
 $taskModels=$taskModelNames |
  ForEach-Object {Join-Path $PdsHome ('arch/vendor/pango/verilog/simulation/'+$_)}
}
foreach($taskPath in $taskSources+$taskModels){if(!(Test-Path -LiteralPath $taskPath)){throw "Missing $taskPath"}}
New-Item -ItemType Directory -Path $taskRun -Force | Out-Null
$taskEvidence=@($PSCommandPath)
if($Case -eq 'source'){$taskEvidence+=@((Join-Path $taskFpga 'sim/check_comms_source.py'),
 (Join-Path $taskFpga 'sim/check_ethernet_tx.py'),(Join-Path $taskFpga '../host/src/pango_video/protocol.py'))}
@($taskSources+$taskModels+$taskEvidence | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
}) | ConvertTo-Json | Set-Content (Join-Path $taskRun 'source_manifest.json') -Encoding utf8
$taskOld=$env:MODELSIM;$taskPassed=$false
function Invoke-BoardSimTool([string]$Tool,[string[]]$ToolArgs,[string]$Log){
 & (Join-Path $ModelSimHome $Tool) @ToolArgs 2>&1 | Tee-Object -FilePath $Log
 if($LASTEXITCODE){throw "$Tool failed: $Log"}
}
Push-Location $taskRun
try {
 Remove-Item Env:MODELSIM -ErrorAction SilentlyContinue
 Invoke-BoardSimTool 'vmap.exe' @('-c') 'vmap.log'
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 Invoke-BoardSimTool 'vlib.exe' @('work') 'vlib.log'
 if($taskModels.Count){Invoke-BoardSimTool 'vlog.exe' $taskModels 'native.log'}
 Invoke-BoardSimTool 'vlog.exe' (@('-sv')+$taskSources) 'compile.log'
 # No wave logging: these long reset/PHY regressions need counters/transcripts,
 # not multi-gigabyte toggle dumps or measured video artifacts.
 @'
onerror {quit -f -code 2}
onbreak {quit -f -code 3}
run -all
quit -f -code 0
'@ | Set-Content run.do -Encoding ascii
 # Native PLL combinational real-number initialization also runs under the
 # simulator optimizer; keep all signals visible for its phase assertions.
 $taskArgs=@('-c','-voptargs=+acc','-t','1ps','-onfinish','exit',('work.'+$taskTop),'-do','do run.do')
 if($Case -eq 'phy'){$taskArgs+=('-gUSE_PHY_DELAY='+$PhyTxDelay)}
 Invoke-BoardSimTool 'vsim.exe' $taskArgs 'simulation.log'
 $taskText=Get-Content simulation.log -Raw
 $taskPassed=$taskText -match $taskMarker -and $taskText -notmatch '\*\* (Error|Fatal)|_FAIL|_TIMEOUT'
 if(!$taskPassed){throw 'Missing PASS or simulation error'}
 if($Case -eq 'source'){
  python -B (Join-Path $taskFpga 'sim/check_comms_source.py') $taskRun | Tee-Object interop.json
  if($LASTEXITCODE){$taskPassed=$false;throw 'Native RGMII/host checker failed'}
 }
} finally {
 [ordered]@{case=$Case;passed=$taskPassed;hardware_tested=$false;programmed=$false} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOld;Pop-Location
}
Write-Output "COMMS_BOARD_SIM_PASS $taskRun"
