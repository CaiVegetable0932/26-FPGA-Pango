# Purpose: board-specific native project, place/route and min/max STA gate.
# Generating an image never opens JTAG/serial/network devices or programs Flash.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$LicenseFile='',
 [ValidateSet('compile','synthesize','pnr','report_timing')][string]$Stage='report_timing',
 [switch]$EmitBitstream)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mini_raw8_dual/native_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskImpl=Join-Path $taskFpga 'build/mini_raw8_dual/implementation'
$taskProject=Join-Path $taskFpga 'project/mini_raw8_dual/mini_raw8_dual.pds'
$taskConstraintDir=Join-Path $taskFpga 'constraints/mini_raw8_dual'
if($EmitBitstream -and $Stage -ne 'report_timing'){throw 'Bitstream requires fresh min/max STA'}
New-Item -ItemType Directory -Path $taskRun,$taskImpl,$taskConstraintDir -Force | Out-Null
# Purpose: include ALL board HDL, native IP and shared constraint inputs in the
# immutable build provenance, not just the newly written RAW8 wrappers.
$taskInputs=@(Get-ChildItem (Join-Path $taskFpga 'rtl/control') -Filter '*.v')+
 @(Get-ChildItem (Join-Path $taskFpga 'rtl/network') -Filter '*.v')+
 @(Get-ChildItem (Join-Path $taskFpga 'rtl/raw8_dual') -File)+
 @(Get-ChildItem $taskConstraintDir -File)+
 @(Get-ChildItem (Join-Path $taskFpga 'rtl/hdmi') -Filter '*.v')
foreach($taskIp in @('ddr3_controller','hdmi_tx_pll','comms_pll','raw8_word_cdc','raw8_capture_cdc')){
 $taskInputs+=Get-ChildItem (Join-Path $taskFpga "ip/$taskIp") -Recurse -File
}
$taskPaths=@($taskInputs.FullName)+@($PSCommandPath,
 (Join-Path $taskFpga 'rtl/board/reset_sync.v'),(Join-Path $taskFpga 'rtl/board/mini_raw8_dual.v'),
 (Join-Path $PSScriptRoot 'create_mini_raw8_dual.tcl'),
 (Join-Path $PSScriptRoot 'export_raw8_sbit.tcl'),
 (Join-Path $taskFpga 'project/mini_raw8_dual/mini_raw8_dual.tcl'))
$taskPaths+=@('rtl/mini_camera_diag/mini_dvp_input.v','rtl/mini_camera_diag/ov5640_sccb.v',
 'rtl/mini_camera_diag/vendor/camera/data_init.v','constraints/mini_camera_diag/ddr_native.fdc',
 'constraints/ddr_board_pins.fdc','constraints/placement.fdc','constraints/mini_camera_diag/routing.rcf') |
 ForEach-Object {Join-Path $taskFpga $_}
@($taskPaths | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}}) |
 ConvertTo-Json | Set-Content (Join-Path $taskRun 'source_manifest.json') -Encoding utf8
function Restore-BoardLayout {
 # Normalize only the native writer's implementation path, not .pds syntax.
 $taskText=Get-Content -LiteralPath $taskProject -Raw
 $taskOld='(_option prj_impl_dir (_string "."))'
 $taskNew='(_option prj_impl_dir (_string "../../build/mini_raw8_dual/implementation"))'
 # Purpose: keep the PDS-native S-expression byte 0 at '('. Windows
 # PowerShell 5.1 Set-Content -Encoding utf8 adds a BOM that Flow-0130 rejects.
 if($taskText.Contains($taskOld)){
  [System.IO.File]::WriteAllText($taskProject,$taskText.Replace($taskOld,$taskNew),
   [System.Text.UTF8Encoding]::new($false))
 }
 elseif(!$taskText.Contains($taskNew)){throw 'Unexpected native implementation path'}
}
$taskOldLicense=$env:PANGO_LICENSE_FILE
if($LicenseFile){$env:PANGO_LICENSE_FILE=(Resolve-Path -LiteralPath $LicenseFile).Path}
$taskPassed=$false;$taskTiming=$false;$taskBitstream=$false
Push-Location $taskRun
try {
 & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'create_mini_raw8_dual.tcl') -work_dir $taskRun 2>&1 | Tee-Object generation.log
 if($LASTEXITCODE -or !(Select-String generation.log -Pattern MINI_RAW8_NATIVE_PROJECT_GENERATED -Quiet)){throw 'Native project generation failed'}
 Restore-BoardLayout
 $taskStart=Get-Date
 & "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskImpl -run $Stage 2>&1 | Tee-Object "$Stage.log"
 if($LASTEXITCODE -or (Select-String "$Stage.log" -Pattern '^E:|Check license failed' -Quiet)){throw 'Native stage failed'}
 Restore-BoardLayout
 $taskSub=@{compile='compile';synthesize='synthesize';pnr='place_route';report_timing='report_timing'}[$Stage]
 $taskExt=@{compile='cmr';synthesize='snr';pnr='prr';report_timing='rtr'}[$Stage]
 $taskReport=Join-Path $taskImpl "$taskSub/mini_raw8_dual.$taskExt"
 if(!(Test-Path $taskReport) -or (Get-Item $taskReport).LastWriteTime -lt $taskStart){throw 'Missing fresh native report'}
 Copy-Item -LiteralPath $taskReport -Destination (Join-Path $taskRun "stage_report.$taskExt")
 $taskPassed=$true
 if($Stage -eq 'report_timing'){
  $taskTiming=[bool](Select-String -LiteralPath $taskReport -Pattern '^Design Summary\s*:\s*All Constraints Met\.' -Quiet)
  if(!$taskTiming){throw 'Place/route completed, but min/max timing is NOT closed'}
  if(Select-String "$Stage.log" -Pattern 'STA-301[35]|cannot find|matches no|No .* found' -Quiet){throw 'Unresolved constraint object: audit before image generation'}
 }
 if($EmitBitstream){
  # Refuse an image if any source was edited while the slow PNR run was active.
  foreach($taskEntry in (Get-Content source_manifest.json -Raw | ConvertFrom-Json)){
   if((Get-FileHash -LiteralPath $taskEntry.path).Hash -ne $taskEntry.sha256){throw 'Build input changed; rebuild before bitstream'}
  }
  $taskImageStart=Get-Date
  # Export the SAME routed DB that passed STA, using the native documented
  # input-db option. A generic project -run would unnecessarily rerun PNR.
  $taskOldDb=$env:RAW8_PNR_DB;$taskOldImpl=$env:RAW8_IMPL
  $env:RAW8_PNR_DB=Join-Path $taskImpl 'place_route/mini_raw8_dual_pnr.adf'
  $env:RAW8_IMPL=$taskImpl
  $taskDbHash=(Get-FileHash -LiteralPath $env:RAW8_PNR_DB).Hash
  try {
   & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'export_raw8_sbit.tcl') -work_dir $taskRun 2>&1 | Tee-Object gen_bit_stream.log
   $taskGenExit=$LASTEXITCODE
   if((Get-FileHash -LiteralPath $env:RAW8_PNR_DB).Hash -ne $taskDbHash){throw 'Audited routed DB changed during export'}
  } finally {$env:RAW8_PNR_DB=$taskOldDb;$env:RAW8_IMPL=$taskOldImpl}
  if($taskGenExit -or !(Select-String gen_bit_stream.log -Pattern RAW8_EXACT_PNR_IMAGE_GENERATED -Quiet) -or
     (Select-String gen_bit_stream.log -Pattern '^E:|Check license failed' -Quiet)){throw 'Bitstream generation failed'}
  Restore-BoardLayout
  $taskImage=Join-Path $taskImpl 'generate_bitstream/mini_raw8_dual.sbit'
  if(!(Test-Path $taskImage) -or (Get-Item $taskImage).LastWriteTime -lt $taskImageStart){throw 'Missing fresh image'}
  Copy-Item -LiteralPath $taskImage -Destination $taskRun
  $taskBitstream=$true
 }
} finally {
 [ordered]@{native_stage_completed=$taskPassed;timing_constraints_met=$taskTiming;
  bitstream_generated=$taskBitstream;hardware_tested=$false;programmed=$false;
  camera_video=$true;physical_mcu_wiring_confirmed=$false;pcb_skew_measured=$false;
  external_dvp_timing_verified=$false;scope='1080p RAW8 camera + HDMI raw grayscale + PRAW Ethernet candidate'} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:PANGO_LICENSE_FILE=$taskOldLicense;Pop-Location
}
Write-Output "MINI_RAW8_NATIVE_PASS $taskRun"
