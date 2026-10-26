# Purpose: snapshot only formal HDMI sources + existing native serializer/PLL,
# then build an isolated traffic fixture. No shared project writes or download.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$LicenseFile='')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/hdmi_display/pnr_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskSource=Join-Path $taskRun 'source'
New-Item -ItemType Directory -Force $taskSource | Out-Null
$taskFiles=@('rtl/video/video_raster.v','rtl/video/rgb888_line_prefetch.v','rtl/video/hdmi_display.v',
 'rtl/video/hdmi_rgb888_tx.v','rtl/video/hdmi_display_pnr_probe.v','rtl/board/tmds_serializer.v',
 'rtl/mini_camera_diag/vendor/hdmi/tmds_encoder.v','constraints/hdmi_display_probe.fdc','config/board.json')
$taskManifest=@()
foreach($taskFile in $taskFiles){
 $taskInput=Join-Path $taskFpga $taskFile;$taskOutput=Join-Path $taskSource $taskFile
 New-Item -ItemType Directory -Force (Split-Path $taskOutput -Parent)|Out-Null
 Copy-Item -LiteralPath $taskInput -Destination $taskOutput
 $taskManifest+=[ordered]@{path=$taskFile;sha256=(Get-FileHash -LiteralPath $taskInput -Algorithm SHA256).Hash.ToLower()}
}
# The generated native IP is copied intact; it is never hand-edited/regenerated.
Copy-Item -LiteralPath (Join-Path $taskFpga 'ip/video_pll') -Destination $taskSource -Recurse
Get-ChildItem (Join-Path $taskSource 'video_pll') -Recurse -File | ForEach-Object{
 $taskManifest+=[ordered]@{path=[IO.Path]::GetRelativePath($taskSource,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()}
}
$taskManifest|ConvertTo-Json -Depth 4|Set-Content (Join-Path $taskRun 'source_snapshot.json')
# Generate dedicated pins from the authority board.json, leaving global FDCs alone.
$taskBoard=Get-Content (Join-Path $taskSource 'config/board.json') -Raw|ConvertFrom-Json
$taskPins=[ordered]@{clk_27m=$taskBoard.pins.clk_27m;reset_n=$taskBoard.pins.reset_n;status_led=$taskBoard.pins.status_led;
 hdmi_clk_p=$taskBoard.pins.hdmi_clk_p;hdmi_clk_n=$taskBoard.pins.hdmi_clk_n}
for($taskLane=0;$taskLane -lt 3;$taskLane++){
 $taskPins["hdmi_data_p[$taskLane]"]=$taskBoard.pins.hdmi_data_p[$taskLane]
 $taskPins["hdmi_data_n[$taskLane]"]=$taskBoard.pins.hdmi_data_n[$taskLane]
}
$taskPinLines=@('# Purpose: same MINI pins as board.json; isolated fixture, not hardware sign-off.')
foreach($taskPort in $taskPins.Keys){
 $taskStandard=if($taskPort.StartsWith('hdmi')){'TMDS'}else{'LVCMOS33'}
 $taskDirection=if($taskPort -in @('clk_27m','reset_n')){'INPUT'}else{'OUTPUT'}
 $taskPinLines+="define_attribute {p:$taskPort} {PAP_IO_DIRECTION} {$taskDirection}"
 $taskPinLines+="define_attribute {p:$taskPort} {PAP_IO_LOC} {$($taskPins[$taskPort])}"
 $taskPinLines+="define_attribute {p:$taskPort} {PAP_IO_VCCIO} {3.3}"
 $taskPinLines+="define_attribute {p:$taskPort} {PAP_IO_STANDARD} {$taskStandard}"
 $taskPinLines+="define_attribute {p:$taskPort} {PAP_IO_NONE} {TRUE}"
}
$taskPinLines|Set-Content (Join-Path $taskSource 'pins.fdc') -Encoding ascii
$taskTcl=@('set src [file join [file dirname [info script]] source]',
 "set_dir -impl_directory {$($taskRun.Replace('\','/'))}",
 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676')
foreach($taskFile in $taskFiles|Where-Object{$_ -like '*.v'}){$taskTcl+='add_design [file join $src '+$taskFile+']'}
$taskTcl+=@('add_design [file join $src video_pll video_pll.idf]',
 'add_constraint [file join $src constraints hdmi_display_probe.fdc]','add_constraint [file join $src pins.fdc]',
 'compile -top_module hdmi_display_pnr_probe','synthesize -ads -selected_syn_tool_opt 2','dev_map',
 'pnr -congest_overlap_limit 20 -action_timeout 15','report_timing -delay_type min_max -max_path 20 -report_exception TRUE')
$taskTcl|Set-Content (Join-Path $taskRun 'probe.tcl') -Encoding ascii
'tcl2prj -tcl [file join [file dirname [info script]] probe.tcl]'|Set-Content (Join-Path $taskRun 'create.tcl') -Encoding ascii
$taskOldLicense=$env:PANGO_LICENSE_FILE
if($LicenseFile){$env:PANGO_LICENSE_FILE=(Resolve-Path -LiteralPath $LicenseFile).Path}
Push-Location $taskRun
try{
 & "$PdsHome/bin/pds_shell.exe" -file create.tcl -work_dir $taskRun 2>&1|Tee-Object generation.log
 if($LASTEXITCODE -or (Get-Content generation.log -Raw) -match '(?m)^E:|Check license failed'){throw 'PDS project creation failed'}
 # -run report_timing rebuilds its prerequisites in this PDS version. A single
 # invocation avoids repeated compile/PnR and stops before power/netlist/bitstream.
 $taskExit=0
 foreach($taskStage in @('report_timing')){
  $taskOutput=& "$PdsHome/bin/pds_shell.exe" -project (Join-Path $taskRun 'probe.pds') -work_dir $taskRun -run $taskStage 2>&1
  $taskExit=$LASTEXITCODE
  $taskOutput|Set-Content "$taskStage.console.log"
  if($taskExit -or ($taskOutput -join "`n") -match '(?m)^E:|Check license failed'){throw "PDS $taskStage failed at $taskRun"}
  Write-Output "HDMI_PROBE_STAGE_FINISHED $taskStage"
 }
 [ordered]@{native_exit=$taskExit;run=$taskRun;hardware_tested=$false;programmed=$false;scope='isolated display + TMDS + local traffic fixture; no native DDR/CDC';timing_signoff=$false}|
 ConvertTo-Json|Set-Content result.json
 Write-Output "HDMI_PROBE_FLOW_FINISHED $taskRun (inspect timing before claiming pass)"
}finally{Pop-Location;$env:PANGO_LICENSE_FILE=$taskOldLicense}
