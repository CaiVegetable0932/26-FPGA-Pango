# Purpose: immutable input snapshot and offline PDS validation of DDR changes.
# Existing GUI project/build output is preserved; no bitstream or hardware access.
param(
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [string]$LicenseFile='',
 # Native -run includes prerequisites; one terminal action avoids repeated PnR.
 [string[]]$Stages=@('report_timing')
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/ddr_dma/pds_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskSnapshot=Join-Path $taskRun 'workspace/fpga'
New-Item -ItemType Directory -Path $taskSnapshot -Force | Out-Null
$taskManifest=@()
# Purpose: copy generated IP inputs verbatim; never regenerate/edit official HDL.
foreach($taskDir in @('rtl','ip','constraints','config','scripts')){
 foreach($taskFile in Get-ChildItem -LiteralPath (Join-Path $taskFpga $taskDir) -Recurse -File){
  if($taskDir -eq 'scripts' -and $taskFile.Extension -notin @('.ps1','.py','.tcl')){continue}
  $taskRelative=[IO.Path]::GetRelativePath($taskFpga,$taskFile.FullName)
  $taskDest=Join-Path $taskSnapshot $taskRelative
  New-Item -ItemType Directory -Path (Split-Path $taskDest -Parent) -Force | Out-Null
  Copy-Item -LiteralPath $taskFile.FullName -Destination $taskDest
  $taskHash=(Get-FileHash -LiteralPath $taskFile.FullName -Algorithm SHA256).Hash
  if((Get-FileHash -LiteralPath $taskDest -Algorithm SHA256).Hash -ne $taskHash){throw 'Snapshot hash mismatch'}
  $taskManifest+=@{path=$taskRelative;sha256=$taskHash}
 }
}
$taskProjectDir=Join-Path $taskSnapshot 'project/mini_camera_diag'
New-Item -ItemType Directory -Path $taskProjectDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskFpga 'project/mini_camera_diag/mini_camera_diag.tcl') -Destination $taskProjectDir
$taskManifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $taskRun 'source_snapshot.json') -Encoding utf8
$taskOldLicense=$env:PANGO_LICENSE_FILE
if($LicenseFile){$env:PANGO_LICENSE_FILE=(Resolve-Path -LiteralPath $LicenseFile).Path}
$taskResults=@()
try {
 # Purpose: use installed project writer and existing reviewed board constraints.
 & (Join-Path $taskSnapshot 'scripts/build_mini_camera_diag.ps1') -PdsHome $PdsHome -LicenseFile $LicenseFile -Stage compile 2>&1 |
  Tee-Object (Join-Path $taskRun 'compile_console.log')
 $taskProject=Join-Path $taskProjectDir 'mini_camera_diag.pds'
 $taskImpl=Join-Path $taskSnapshot 'build/mini_camera_diag/implementation'
 foreach($taskStage in $Stages){
  if($taskStage -eq 'compile'){continue}
  if($taskStage -notin @('synthesize','dev_map','pnr','report_timing')){throw 'Only offline non-bitstream stages allowed'}
  $taskStart=Get-Date
  Push-Location $taskRun
  try { $taskOutput=& "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskImpl -run $taskStage 2>&1;$taskExit=$LASTEXITCODE } finally {Pop-Location}
  $taskOutput | Set-Content (Join-Path $taskRun "$taskStage.log") -Encoding utf8
  $taskExt=@{synthesize='snr';dev_map='dmr';pnr='prr';report_timing='rtr'}[$taskStage]
  $taskDir=@{synthesize='synthesize';dev_map='device_map';pnr='place_route';report_timing='report_timing'}[$taskStage]
  $taskReports=@(Get-ChildItem (Join-Path $taskImpl $taskDir) -Filter "*.$taskExt" -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -ge $taskStart})
  $taskPass=$taskExit -eq 0 -and $taskReports.Count -gt 0 -and ($taskOutput -join "`n") -notmatch '(?m)^E:|Check license failed'
  $taskResults+=@{stage=$taskStage;native_exit=$taskExit;stage_completed=$taskPass;reports=@($taskReports.FullName)}
  $taskResults | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $taskRun 'stages.json') -Encoding utf8
  Write-Output "DDR_PDS_STAGE stage=$taskStage completed=$taskPass"
  if(!$taskPass){throw "Native stage failed: $taskStage ($taskRun)"}
 }
 # Purpose: verify actual diagnostic dependencies and list unrelated partition
 # edits separately; this build never certifies those unused sources.
 & python (Join-Path $PSScriptRoot 'audit_ddr_snapshot.py') $taskRun
 if($LASTEXITCODE){throw 'Diagnostic dependency changed during validation'}
 Write-Output "DDR_PDS_OFFLINE_COMPLETE $taskRun (stage completion does not certify external timing)"
} finally { $env:PANGO_LICENSE_FILE=$taskOldLicense }
