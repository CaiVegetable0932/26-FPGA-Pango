# Purpose: native project generation/reopen and offline compile or ADS synthesis.
# No bitstream, programmer, serial port, network interface or system setting is used.
param(
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [string]$LicenseFile='',
 [ValidateSet('compile','synthesize')][string]$Stage='synthesize'
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/fpga_comms/native_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskImpl=Join-Path $taskFpga 'build/fpga_comms/implementation'
$taskProject=Join-Path $taskFpga 'project/fpga_comms/fpga_comms.pds'
New-Item -ItemType Directory -Path $taskRun,$taskImpl -Force | Out-Null
# Purpose: native logs must identify the exact new hierarchy and constraints,
# not merely the repository base commit; never hash or copy license contents.
$taskInputs=@(Get-ChildItem (Join-Path $taskFpga 'rtl/control') -Filter 'mcu_*.v') +
 @((Get-Item (Join-Path $taskFpga 'rtl/control/fpga_comms_top.v')))
$taskInputs+=@('praw_packetizer.v','udp_ipv4_eth_tx.v','video_network_tx.v','pango_rgmii_tx.v') |
 ForEach-Object {Get-Item (Join-Path $taskFpga "rtl/network/$_")}
$taskPaths=@($taskInputs | ForEach-Object {$_.FullName}) + @($PSCommandPath,
 (Join-Path $taskFpga 'project/fpga_comms/fpga_comms.tcl'),
 (Join-Path $taskFpga 'constraints/fpga_comms_clocks.fdc'),
 (Join-Path $PSScriptRoot 'create_fpga_comms.tcl'))
@($taskPaths | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
}) | ConvertTo-Json | Set-Content (Join-Path $taskRun 'source_manifest.json') -Encoding utf8
$taskOldLicense=$env:PANGO_LICENSE_FILE
if($LicenseFile){$env:PANGO_LICENSE_FILE=(Resolve-Path -LiteralPath $LicenseFile).Path}

function Restore-CommsLayout {
 # Purpose: PDS may persist '.' after a run. Normalize this single generated
 # option to the verified development layout, preserving all native grouping.
 $taskText=Get-Content -LiteralPath $taskProject -Raw
 $taskNative='(_option prj_impl_dir (_string "."))'
 $taskRelative='(_option prj_impl_dir (_string "../../build/fpga_comms/implementation"))'
 if($taskText.Contains($taskNative)){
  $taskText.Replace($taskNative,$taskRelative) | Set-Content -LiteralPath $taskProject -Encoding utf8
 } elseif(!$taskText.Contains($taskRelative)){throw 'Unexpected native implementation directory'}
}
try {
 Push-Location $taskRun
 try {
  & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'create_fpga_comms.tcl') -work_dir $taskRun 2>&1 | Tee-Object generation.log
  if($LASTEXITCODE -or !(Select-String -Path generation.log -Pattern 'FPGA_COMMS_NATIVE_PROJECT_GENERATED' -Quiet) -or
     (Select-String -Path generation.log -Pattern '^E:|Check license failed' -Quiet)){throw 'Native project generation failed'}
  Restore-CommsLayout
  $taskStart=Get-Date
  & "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskImpl -run $Stage 2>&1 | Tee-Object "$Stage.log"
  $taskExit=$LASTEXITCODE
  Restore-CommsLayout
  $taskExt=@{compile='cmr';synthesize='snr'}[$Stage]
  $taskReports=@(Get-ChildItem (Join-Path $taskImpl $Stage) -Filter "*.$taskExt" -ErrorAction SilentlyContinue |
   Where-Object {$_.LastWriteTime -ge $taskStart})
  $taskPass=$taskExit -eq 0 -and $taskReports.Count -gt 0 -and
   !(Select-String -Path "$Stage.log" -Pattern '^E:|Check license failed' -Quiet)
  # Purpose: a successful synthesis process is NOT a timing pass. Retain the
  # native estimate separately; full board/clock-tree PNR is outside this project.
  $taskTimingMet=$null
  if($Stage -eq 'synthesize' -and $taskReports.Count -gt 0){
   $taskTimingMet=[bool](Select-String -LiteralPath $taskReports[0].FullName -Pattern 'Design Summary : All Constraints Met' -Quiet)
   Copy-Item -LiteralPath $taskReports[0].FullName -Destination (Join-Path $taskRun 'synthesis_report.snr')
  }
  [ordered]@{stage=$Stage;passed=$taskPass;native_exit=$taskExit;fresh_reports=$taskReports.Count;
   synthesis_estimate_all_constraints_met=$taskTimingMet;place_route_run=$false;
   hardware_tested=$false;programmed=$false;external_timing_verified=$false;
   scope='internal subsystem synthesis; not board IO or place-and-route'} | ConvertTo-Json | Set-Content result.json -Encoding utf8
  if(!$taskPass){throw 'Native communications stage failed; retained evidence must be inspected'}
  if($taskTimingMet -eq $false){Write-Warning 'Synthesis completed but timing estimate has violations; NOT cleared for board use.'}
  Write-Output "FPGA_COMMS_NATIVE_PASS $taskRun"
 } finally {Pop-Location}
} finally {$env:PANGO_LICENSE_FILE=$taskOldLicense}
