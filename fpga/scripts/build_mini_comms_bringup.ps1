# Purpose: board-specific native project, place/route and min/max STA gate.
# Generating an image never opens JTAG/serial/network devices or programs Flash.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$LicenseFile='',
 [ValidateSet('compile','synthesize','pnr','report_timing')][string]$Stage='report_timing',
 [switch]$EmitBitstream)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mini_comms_bringup/native_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskImpl=Join-Path $taskFpga 'build/mini_comms_bringup/implementation'
$taskProject=Join-Path $taskFpga 'project/mini_comms_bringup/mini_comms_bringup.pds'
$taskConstraintDir=Join-Path $taskFpga 'constraints/mini_comms_bringup'
if($EmitBitstream -and $Stage -ne 'report_timing'){throw 'Bitstream requires fresh min/max STA'}
New-Item -ItemType Directory -Path $taskRun,$taskImpl,$taskConstraintDir -Force | Out-Null
# Copy reviewed native pin attributes, filtering out unused camera/DDR/RX pins.
$taskPorts=@('ref_clk_p','ref_clk_n','reset_n','rgmii_txc','rgmii_tx_ctl',
 'rgmii_txd[0]','rgmii_txd[1]','rgmii_txd[2]','rgmii_txd[3]',
 'phy_reset_n','phy_mdc','phy_mdio')
$taskPins=[Collections.Generic.List[string]]::new()
$taskPins.Add('# Purpose: MINI V1.3 pins; generated only in this isolated project.')
foreach($taskLine in Get-Content (Join-Path $taskFpga 'constraints/board_pins.fdc')){
 if($taskLine -match '^define_attribute \{p:([^}]+)\}' -and $Matches[1] -in $taskPorts){
  # 16 mA FAST on all six matched RGMII outputs; lower drive caused excessive
  # rising/falling I/O delay difference in the installed production STA model.
  if($Matches[1] -like 'rgmii_t*' -and $taskLine.Contains('{PAP_IO_DRIVE}')){
   $taskLine=$taskLine.Replace('{PAP_IO_DRIVE} {4}','{PAP_IO_DRIVE} {16}')
  }
  $taskPins.Add($taskLine)
 }
}
foreach($taskPin in @(@('uart_rx','B24','INPUT'),@('uart_tx','C24','OUTPUT'),
 @('led[0]','A20','OUTPUT'),@('led[1]','C19','OUTPUT'),@('led[2]','C18','OUTPUT'),
 @('led[3]','E18','OUTPUT'),@('led[4]','A17','OUTPUT'))){
 $taskPort=$taskPin[0]
 $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_DIRECTION} {$($taskPin[2])}")
 $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_LOC} {$($taskPin[1])}")
 $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_VCCIO} {3.3}")
 $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_STANDARD} {LVCMOS33}")
 $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_NONE} {TRUE}")
 if($taskPin[2] -eq 'OUTPUT'){
  $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_DRIVE} {4}")
  $taskPins.Add("define_attribute {p:$taskPort} {PAP_IO_SLEW} {SLOW}")
 }
}
$taskPins | Set-Content (Join-Path $taskConstraintDir 'pins.fdc') -Encoding utf8
$taskInputs=@(Get-ChildItem (Join-Path $taskFpga 'rtl/control') -Filter '*.v')+
 @(Get-ChildItem (Join-Path $taskFpga 'rtl/network') -Filter '*.v')+
 @(Get-ChildItem (Join-Path $taskFpga 'ip/comms_pll') -File)+
 @(Get-ChildItem $taskConstraintDir -File)
$taskPaths=@($taskInputs.FullName)+@($PSCommandPath,
 (Join-Path $taskFpga 'rtl/board/reset_sync.v'),(Join-Path $taskFpga 'rtl/board/mini_comms_bringup.v'),
 (Join-Path $PSScriptRoot 'create_mini_comms_bringup.tcl'),
 (Join-Path $taskFpga 'project/mini_comms_bringup/mini_comms_bringup.tcl'))
@($taskPaths | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}}) |
 ConvertTo-Json | Set-Content (Join-Path $taskRun 'source_manifest.json') -Encoding utf8
function Restore-BoardLayout {
 # Normalize only the native writer's implementation path, not .pds syntax.
 $taskText=Get-Content -LiteralPath $taskProject -Raw
 $taskOld='(_option prj_impl_dir (_string "."))'
 $taskNew='(_option prj_impl_dir (_string "../../build/mini_comms_bringup/implementation"))'
 if($taskText.Contains($taskOld)){$taskText.Replace($taskOld,$taskNew)|Set-Content -LiteralPath $taskProject -Encoding utf8}
 elseif(!$taskText.Contains($taskNew)){throw 'Unexpected native implementation path'}
}
$taskOldLicense=$env:PANGO_LICENSE_FILE
if($LicenseFile){$env:PANGO_LICENSE_FILE=(Resolve-Path -LiteralPath $LicenseFile).Path}
$taskPassed=$false;$taskTiming=$false;$taskBitstream=$false
Push-Location $taskRun
try {
 & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'create_mini_comms_bringup.tcl') -work_dir $taskRun 2>&1 | Tee-Object generation.log
 if($LASTEXITCODE -or !(Select-String generation.log -Pattern MINI_COMMS_NATIVE_PROJECT_GENERATED -Quiet)){throw 'Native project generation failed'}
 Restore-BoardLayout
 $taskStart=Get-Date
 & "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskImpl -run $Stage 2>&1 | Tee-Object "$Stage.log"
 if($LASTEXITCODE -or (Select-String "$Stage.log" -Pattern '^E:|Check license failed' -Quiet)){throw 'Native stage failed'}
 Restore-BoardLayout
 $taskSub=@{compile='compile';synthesize='synthesize';pnr='place_route';report_timing='report_timing'}[$Stage]
 $taskExt=@{compile='cmr';synthesize='snr';pnr='prr';report_timing='rtr'}[$Stage]
 $taskReport=Join-Path $taskImpl "$taskSub/mini_comms_bringup.$taskExt"
 if(!(Test-Path $taskReport) -or (Get-Item $taskReport).LastWriteTime -lt $taskStart){throw 'Missing fresh native report'}
 Copy-Item -LiteralPath $taskReport -Destination (Join-Path $taskRun "stage_report.$taskExt")
 $taskPassed=$true
 if($Stage -eq 'report_timing'){
  $taskTiming=[bool](Select-String -LiteralPath $taskReport -Pattern '^Design Summary\s*:\s*All Constraints Met\.' -Quiet)
  if(!$taskTiming){throw 'Place/route completed, but min/max timing is NOT closed'}
  if(Select-String "$Stage.log" -Pattern 'STA-301[35]|cannot find|matches no|No .* found' -Quiet){throw 'Unresolved constraint object: audit before image generation'}
 }
 if($EmitBitstream){
  $taskImageStart=Get-Date
  & "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskImpl -run gen_bit_stream 2>&1 | Tee-Object gen_bit_stream.log
  if($LASTEXITCODE -or (Select-String gen_bit_stream.log -Pattern '^E:|Check license failed' -Quiet)){throw 'Bitstream generation failed'}
  Restore-BoardLayout
  $taskImage=Join-Path $taskImpl 'generate_bitstream/mini_comms_bringup.sbit'
  if(!(Test-Path $taskImage) -or (Get-Item $taskImage).LastWriteTime -lt $taskImageStart){throw 'Missing fresh image'}
  Copy-Item -LiteralPath $taskImage -Destination $taskRun
  $taskBitstream=$true
 }
} finally {
 [ordered]@{native_stage_completed=$taskPassed;timing_constraints_met=$taskTiming;
  bitstream_generated=$taskBitstream;hardware_tested=$false;programmed=$false;
  camera_video=$false;physical_mcu_wiring_confirmed=$false;pcb_skew_measured=$false;
  scope='isolated synthetic traffic + CP2102 MCU emulator commissioning image'} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:PANGO_LICENSE_FILE=$taskOldLicense;Pop-Location
}
Write-Output "MINI_COMMS_NATIVE_PASS $taskRun"
