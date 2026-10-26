# Purpose: repeatable offline formal HDMI regressions; outputs stay in fpga/build.
# No PDS download or capture-card operation is performed by this script.
param(
 [ValidateSet('Icarus','ModelSim')][string]$Simulator='Icarus',
 [string]$IcarusHome='', [string]$ModelSimHome='E:/ModelsimSE/win64',
 [switch]$SkipFull,
 [ValidateSet('faults','1080p30','mixed_dma','encoding','mini_video')][string[]]$Cases=@()
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'}
$taskRun=Join-Path $taskFpga ('build/hdmi_display/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Force $taskRun | Out-Null
$taskMainNames=@('rtl/video/video_raster.v','rtl/video/rgb888_line_prefetch.v','rtl/video/hdmi_display.v','rtl/memory/ddr_native_dma.v','sim/tb_hdmi_display.sv')
$taskExtraNames=@('rtl/mini_camera_diag/vendor/hdmi/tmds_encoder.v','rtl/video/hdmi_rgb888_tx.v',
 'sim/hdmi_encoder_only_stubs.v','sim/tb_hdmi_tmds.sv','rtl/mini_camera_diag/vendor/sync_vg.v',
 'rtl/mini_camera_diag/vendor/timing_gen_xy.v','rtl/mini_camera_diag/vendor/video_rect_read_data.v','sim/tb_mini_video.sv')
$taskCopy=Join-Path $taskRun 'source';$taskHashes=@()
# Freeze and hash inputs before compilation so edits during a long full-frame
# simulation can never be attributed to a previously compiled executable.
foreach($taskName in @($taskMainNames+$taskExtraNames)){
 $taskOriginal=Join-Path $taskFpga $taskName;$taskCopied=Join-Path $taskCopy $taskName
 New-Item -ItemType Directory -Force (Split-Path $taskCopied -Parent)|Out-Null
 Copy-Item -LiteralPath $taskOriginal -Destination $taskCopied
 $taskDigest=(Get-FileHash -LiteralPath $taskCopied -Algorithm SHA256).Hash.ToLower()
 if($taskDigest -ne (Get-FileHash -LiteralPath $taskOriginal -Algorithm SHA256).Hash.ToLower()){throw "Input changed while snapshotting: $taskName"}
 $taskHashes+=[ordered]@{path=$taskName;snapshot=$taskCopied;sha256=$taskDigest}
}
$taskHashes|ConvertTo-Json -Depth 4|Set-Content (Join-Path $taskRun 'source_snapshot.json')
$taskSources=$taskMainNames|ForEach-Object{Join-Path $taskCopy $_}
Push-Location $taskRun
try {
 if($Simulator -eq 'ModelSim'){
  & "$ModelSimHome/vlib.exe" work 2>&1 | Tee-Object library.log
  if($LASTEXITCODE){throw 'vlib failed'}
  & "$ModelSimHome/vlog.exe" -sv -work work @taskSources 2>&1 | Tee-Object compile.log
  if($LASTEXITCODE){throw 'vlog failed'}
 }
 $taskCases=@('faults','mixed_dma');if($Simulator -eq 'Icarus'){$taskCases+=@('encoding','mini_video')}
 if(!$SkipFull){$taskCases+=@('1080p30')}
 if($Cases.Count){$taskCases=$Cases}
 $taskResults=[ordered]@{}
 foreach($taskCase in $taskCases){
  $taskFull=0;if($taskCase -eq '1080p30'){$taskFull=1}
  $taskNative=0;if($taskCase -eq 'mixed_dma'){$taskNative=1}
  $taskTop='tb_hdmi_display';$taskMarker='HDMI_DISPLAY_PASS';$taskExtra=@();$taskDefines=@()
  if($taskCase -in @('encoding','mini_video')){
   $taskTop=if($taskCase -eq 'encoding'){'tb_hdmi_tmds'}else{'tb_mini_video'}
   $taskMarker=if($taskCase -eq 'encoding'){'HDMI_TMDS_PASS'}else{'VIDEO_PASS'}
   $taskExtra=$taskExtraNames|ForEach-Object{Join-Path $taskCopy $_}
   $taskDefines=@('-DHDMI_ENCODER_ONLY')
  }
  if($Simulator -eq 'Icarus'){
   & "$IcarusHome/iverilog.exe" -g2012 -s $taskTop "-Ptb_hdmi_display.FULL=$taskFull" "-Ptb_hdmi_display.NATIVE=$taskNative" @taskDefines -o "$taskCase.vvp" @taskSources @taskExtra 2>&1 | Tee-Object "$taskCase.compile.log"
   if($LASTEXITCODE){throw "Compile failed: $taskCase"}
   & "$IcarusHome/vvp.exe" "$taskCase.vvp" 2>&1 | Tee-Object "$taskCase.log"
  }else{
   if($taskExtra.Count){throw 'encoding/mini_video portable cases use Icarus; native TMDS uses sim_hdmi_tmds.ps1'}
   & "$ModelSimHome/vsim.exe" -c -lib ./work $taskTop "-gFULL=$taskFull" "-gNATIVE=$taskNative" -do 'onbreak {quit -f -code 1}; onerror {quit -f -code 2}; run -all; quit -f' 2>&1 | Tee-Object "$taskCase.log"
  }
  $taskExit=$LASTEXITCODE;$taskText=Get-Content "$taskCase.log" -Raw
  $taskResults[$taskCase]=$taskExit -eq 0 -and $taskText -match $taskMarker -and $taskText -notmatch '_FAIL|_TIMEOUT|\*\* (Error|Fatal)'
  if(!$taskResults[$taskCase]){throw "Regression failed: $taskCase at $taskRun"}
 }
 [ordered]@{run=$taskRun;simulator=$Simulator;cases=$taskResults;sources=$taskHashes;passed=$true;hardware_tested=$false;programmed=$false} |
 ConvertTo-Json -Depth 6 | Set-Content result.json -Encoding UTF8
 Write-Output "HDMI_DISPLAY_OFFLINE_PASS $taskRun"
}finally{Pop-Location}
