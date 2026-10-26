# Purpose: offline restart/RGMII/TMDS regression using installed PDS models.
# Copies proprietary model dependencies unchanged into a fresh FPGA run folder.
# Compile success alone cannot count as simulation success or board sign-off.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/clock_reset_20261012/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskVendor=Join-Path $taskRun 'vendor'
New-Item -ItemType Directory -Force $taskVendor|Out-Null
$taskNative=Join-Path $PdsHome 'arch/vendor/pango/verilog/simulation'
Copy-Item -LiteralPath (Join-Path $taskNative 'modelsim10.2c') -Destination $taskVendor -Recurse
$taskModels=@('GTP_GRS','GTP_CLKBUFG','GTP_IDDR_E1','GTP_ODDR_E1','GTP_IOCLKDIV_E2','GTP_OSERDES_E2','GTP_OUTBUFDS')
foreach($taskName in $taskModels){Copy-Item -LiteralPath (Join-Path $taskNative "$taskName.v") -Destination $taskVendor}
[ordered]@{source=$taskNative;pds_version='2022.2-SP6.4';modifications='none; offline copies'}|
 ConvertTo-Json|Set-Content (Join-Path $taskRun 'vendor_source.json')
Push-Location $taskRun
try{
 & "$ModelSimHome/vlib.exe" work 2>&1|Tee-Object library.log
 if($LASTEXITCODE){throw 'vlib failed'}
 Push-Location (Join-Path $taskVendor 'modelsim10.2c')
 try{
  & "$ModelSimHome/vlog.exe" -work (Join-Path $taskRun 'work') -f filelist_oserdes_e2_gtp.f -l (Join-Path $taskRun 'native.log')
  if($LASTEXITCODE){throw 'native compile failed'}
 }finally{Pop-Location}
 $taskSources=@('rtl/board/reset_sync.v','rtl/board/video_clock_start.v','rtl/board/rgmii_phy_io.v','rtl/board/tmds_serializer.v',
  'sim/tb_video_clock_start.sv','sim/tb_board_io.sv','sim/tb_tmds_serializer.sv')|ForEach-Object{Join-Path $taskFpga $_}
 $taskPrimitives=$taskModels|ForEach-Object{Join-Path $taskVendor "$_.v"}
 & "$ModelSimHome/vlog.exe" -sv -work work @taskPrimitives @taskSources 2>&1|Tee-Object compile.log
 if($LASTEXITCODE){throw 'RTL compile failed'}
 $taskCases=[ordered]@{video_clock_start='VIDEO_START_PASS';board_io='BOARD_IO_PASS';tmds_serializer='TMDS_PASS'}
 foreach($taskCase in $taskCases.Keys){
  & "$ModelSimHome/vsim.exe" -c -lib ./work "tb_$taskCase" -do 'onbreak {quit -f -code 1}; onerror {quit -f -code 2}; run -all; quit -f -code 0' 2>&1|Tee-Object "$taskCase.log"
  $taskExit=$LASTEXITCODE;$taskText=Get-Content "$taskCase.log" -Raw
  if($taskExit -or $taskText -notmatch $taskCases[$taskCase] -or $taskText -match '_FAIL|_TIMEOUT|\*\* (Error|Fatal)'){throw "Failed $taskCase"}
 }
 [ordered]@{passed=$true;cases=@($taskCases.Keys);hardware_tested=$false;programmed=$false}|
  ConvertTo-Json|Set-Content result.json
 Write-Output "CLOCK_RESET_NATIVE_SIM_PASS $taskRun"
}catch{
 # Keep license failures distinct from a functional failure or a completed TB.
 $taskLicenseBlocked=@(Get-ChildItem -LiteralPath $taskRun -Filter '*.log'|Select-String 'Failure to obtain a Verilog simulation license').Count -gt 0
 [ordered]@{passed=$false;license_blocked=$taskLicenseBlocked;reason=$_.Exception.Message;hardware_tested=$false;programmed=$false}|
  ConvertTo-Json|Set-Content result.json
 throw
}finally{Pop-Location}
