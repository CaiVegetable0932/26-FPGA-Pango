# Purpose: compile read-only installation primitive copies into a fresh local
# ModelSim library. Verify native serializer and three-channel TMDS/tag mapping.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/hdmi_display/tmds_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskNative=Join-Path $PdsHome 'arch/vendor/pango/verilog/simulation'
New-Item -ItemType Directory -Force $taskRun | Out-Null
$taskVendor=Join-Path $taskRun 'vendor'
New-Item -ItemType Directory -Force $taskVendor | Out-Null
# Copy only required encrypted primitive dependencies, preserving their sources.
Copy-Item -LiteralPath (Join-Path $taskNative 'modelsim10.2c') -Destination $taskVendor -Recurse
foreach($taskName in @('GTP_GRS.v','GTP_IOCLKDIV_E2.v','GTP_OSERDES_E2.v','GTP_OUTBUFDS.v')){
 Copy-Item -LiteralPath (Join-Path $taskNative $taskName) -Destination $taskVendor
}
[ordered]@{source=$taskNative;pds_version='2022.2-SP6.4';modifications='none; copied for offline simulation'} | ConvertTo-Json | Set-Content (Join-Path $taskRun 'vendor_source.json')
Push-Location $taskRun
$taskCompilePassed=$false
try{
 & "$ModelSimHome/vlib.exe" work 2>&1 | Tee-Object library.log
 if($LASTEXITCODE){throw 'vlib failed'}
 $taskWork=(Join-Path $taskRun 'work').Replace('\','/')
 Push-Location (Join-Path $taskVendor 'modelsim10.2c')
 try{
  & "$ModelSimHome/vlog.exe" -work $taskWork -f filelist_oserdes_e2_gtp.f -l (Join-Path $taskRun 'native.log')
  if($LASTEXITCODE){throw 'native library compile failed'}
 }finally{Pop-Location}
 # Include the production restart controller used by the native serializer TB.
 $taskSources=@('rtl/board/reset_sync.v','rtl/board/video_clock_start.v','rtl/board/tmds_serializer.v','rtl/mini_camera_diag/vendor/hdmi/tmds_encoder.v',
 'rtl/video/hdmi_rgb888_tx.v','sim/tb_tmds_serializer.sv','sim/tb_hdmi_tmds.sv')|ForEach-Object{Join-Path $taskFpga $_}
 $taskPrimitives=@('GTP_GRS.v','GTP_IOCLKDIV_E2.v','GTP_OSERDES_E2.v','GTP_OUTBUFDS.v')|ForEach-Object{Join-Path $taskVendor $_}
 & "$ModelSimHome/vlog.exe" -sv -work work @taskPrimitives @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'TMDS compile failed'}
 $taskCompilePassed=$true
 $taskResults=[ordered]@{}
 foreach($taskCase in @('tmds_serializer','hdmi_tmds')){
  & "$ModelSimHome/vsim.exe" -c -lib ./work "tb_$taskCase" -do 'onbreak {quit -f -code 1}; onerror {quit -f -code 2}; run -all; quit -f -code 0' 2>&1 | Tee-Object "$taskCase.log"
  $taskExit=$LASTEXITCODE;$taskText=Get-Content "$taskCase.log" -Raw
  $taskMarker=if($taskCase -eq 'tmds_serializer'){'TMDS_PASS'}else{'HDMI_TMDS_PASS'}
  $taskResults[$taskCase]=$taskExit -eq 0 -and $taskText -match $taskMarker -and $taskText -notmatch '_FAIL|_TIMEOUT|\*\* (Error|Fatal)'
  if(!$taskResults[$taskCase]){throw "TMDS regression failed: $taskCase at $taskRun"}
 }
 [ordered]@{cases=$taskResults;passed=$true;hardware_tested=$false;programmed=$false} | ConvertTo-Json | Set-Content result.json
 Write-Output "HDMI_NATIVE_TMDS_PASS $taskRun"
}catch{
 # Preserve failed/licensed-out evidence as such; compilation success alone
 # must never be published as a serializer functional regression pass.
 $taskLicenseBlocked=@(Get-ChildItem -LiteralPath $taskRun -Filter '*.log'|Select-String 'Failure to obtain a Verilog simulation license').Count -gt 0
 [ordered]@{passed=$false;compiled=$taskCompilePassed;license_blocked=$taskLicenseBlocked;
 reason=$_.Exception.Message;hardware_tested=$false;programmed=$false}|
 ConvertTo-Json|Set-Content result.json
 throw
}finally{Pop-Location}
