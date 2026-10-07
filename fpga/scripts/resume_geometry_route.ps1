# Purpose: verify checkpoint provenance, resume native routing into a fresh
# directory, and export the exact DB only after passing final min/max timing.
# It never opens board devices. A larger execution limit is not a timing waiver.
param([Parameter(Mandatory=$true)][string]$Checkpoint,
 [ValidateRange(0,1000)][int]$NewPlacementSeed=0,
 [ValidateRange(0,9)][int]$Decongestion=3,
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [ValidateSet('ten','critical37')][string]$Profile='ten')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskCheckpoint=(Resolve-Path -LiteralPath $Checkpoint).Path
$taskBuild=[IO.Path]::GetFullPath((Join-Path $taskFpga 'build'))
if(!$taskCheckpoint.StartsWith($taskBuild+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Checkpoint must belong to fpga/build'}
$taskSources=Get-Content (Join-Path $taskCheckpoint 'source_manifest.json') -Raw | ConvertFrom-Json
$taskDdrAudit=Join-Path $taskCheckpoint 'ddr_placement_audit.json'
$taskHasDdr=Test-Path -LiteralPath $taskDdrAudit
# The profile helper is a separate physical input, not part of RTL mapping.
# Freeze it at entry and in checkpoint_hashes so changes during PNR fail closed.
$taskScopePath=Join-Path $PSScriptRoot 'geometry_ddr_scope.ps1'
$taskScopeHash=(Get-FileHash -LiteralPath $taskScopePath).Hash
. $taskScopePath
if($Profile -ne 'ten' -and !$taskHasDdr){throw 'Explicit DDR profile requires its merge audit'}
if($taskHasDdr -and !$NewPlacementSeed){throw 'A new DDR placement delta requires fresh native placement'}
function Assert-CheckpointSources {
 # Both preflight and final export must match the checkpoint's source inputs.
 foreach($taskSource in $taskSources){
  if((Get-FileHash -LiteralPath $taskSource.path).Hash -ne $taskSource.sha256){throw "Checkpoint source changed: $($taskSource.path)"}
 }
 # Purpose: a post-map delta is separate physical input, never hidden behind
 # an unchanged RTL manifest. Bind its complete board prefix, reviewed delta,
 # merge runner and mapped database before and after native implementation.
 if($taskHasDdr){
  $audit=Get-Content -LiteralPath $taskDdrAudit -Raw | ConvertFrom-Json
  if((Get-FileHash -LiteralPath $taskScopePath).Hash -cne $taskScopeHash){throw 'DDR profile helper changed'}
  Assert-GeometryDdrAuditPolicy $audit $Profile $taskScopePath
  foreach($entry in @($audit.inputs)+@($audit.output)){
   if((Get-FileHash -LiteralPath $entry.path).Hash -ne $entry.sha256){throw "DDR physical input changed: $($entry.path)"}
  }
  $merged=Join-Path $taskCheckpoint 'mini_raw8_geometry.pcf'
  if([IO.Path]::GetFullPath($audit.output.path) -ne [IO.Path]::GetFullPath($merged)){throw 'DDR audit is not bound to the loaded PCF'}
 }
}
Assert-CheckpointSources
$taskRun=Join-Path $taskFpga ('build/mini_raw8_geometry/resumed_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
Copy-Item -LiteralPath (Join-Path $taskCheckpoint 'source_manifest.json') -Destination $taskRun
if($taskHasDdr){Copy-Item -LiteralPath $taskDdrAudit -Destination $taskRun}
$taskOld=@{}
foreach($taskName in @('PANGO_LICENSE_FILE','GEOMETRY_MAP_DB','GEOMETRY_MAP_PCF','GEOMETRY_PLACE_DB','GEOMETRY_RESUME_IMPL','GEOMETRY_IMPL','GEOMETRY_PNR_DB','GEOMETRY_NEW_SEED','GEOMETRY_DECONGESTION')){
 $taskOld[$taskName]=[Environment]::GetEnvironmentVariable($taskName,'Process')
}
$taskTiming=$false;$taskImage=$false;$taskUnchanged=$false;$taskRouted=$false
Push-Location $taskRun
try {
 if(!$env:PANGO_LICENSE_FILE){$env:PANGO_LICENSE_FILE=[Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','User')}
 $env:GEOMETRY_MAP_DB=Join-Path $taskCheckpoint 'mini_raw8_geometry_map.adf'
 $env:GEOMETRY_MAP_PCF=Join-Path $taskCheckpoint 'mini_raw8_geometry.pcf'
 $env:GEOMETRY_PLACE_DB=Join-Path $taskCheckpoint 'mini_raw8_geometry_plc.adf'
 $env:GEOMETRY_RESUME_IMPL=$taskRun
 # A positive seed creates a fresh placement from the verified mapped DB;
 # zero resumes its saved placement. Neither mode reuses an old routed DB.
 $env:GEOMETRY_NEW_SEED=[string]$NewPlacementSeed
 # Native 0..9 area-expansion control only; never a timing-budget override.
 $env:GEOMETRY_DECONGESTION=[string]$Decongestion
 # Preserve hashes of the exact checkpoint and runner used for this attempt.
 $taskCheckpointFiles=@($env:GEOMETRY_MAP_DB,$PSCommandPath,(Join-Path $PSScriptRoot 'resume_geometry_route.tcl'))
 if($NewPlacementSeed){$taskCheckpointFiles+=$env:GEOMETRY_MAP_PCF}
 if(!$NewPlacementSeed){$taskCheckpointFiles+=$env:GEOMETRY_PLACE_DB}
 if($taskHasDdr){$taskCheckpointFiles+=@($taskDdrAudit,$taskScopePath,
  (Join-Path $PSScriptRoot 'inspect_geometry_ddr_placement.tcl'),
  (Join-Path $PSScriptRoot 'verify_geometry_ddr_placement.ps1'))}
 $taskCheckpointFiles |
  ForEach-Object {Get-FileHash -LiteralPath $_} | ConvertTo-Json | Set-Content checkpoint_hashes.json -Encoding utf8
 & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'resume_geometry_route.tcl') -work_dir $taskRun 2>&1 | Tee-Object route.log
 if($LASTEXITCODE -or !(Select-String route.log -Pattern GEOMETRY_CHECKPOINT_PROJECT_CONFIGURED -Quiet) -or
  (Select-String route.log -Pattern '^E:|STA-301[35]|cannot find|matches no|No .* found' -Quiet)){throw 'Checkpoint native flow failed'}
 # Purpose: one native PNR invocation only. Missing output is a failure,
 # never permission to rerun PNR and destroy a previous implementation DB.
 $taskRoutedDb=Join-Path $taskRun 'place_route/mini_raw8_geometry_pnr.adf'
 if(!(Test-Path -LiteralPath $taskRoutedDb)){throw 'Native routing returned without its routed DB'}
 $taskRouted=$true
 # Archive the exact database before STA/export can create new reports.
 # Subsequent tools consume this snapshot, not a mutable implementation path.
 $taskArchive=Join-Path $taskRun 'routed_snapshot'
 New-Item -ItemType Directory -Path $taskArchive | Out-Null
 Copy-Item -LiteralPath $taskRoutedDb -Destination $taskArchive
 # The PNR companion is the native GOP/type inventory; generated simulation
 # Verilog is a different representation and must not satisfy this check.
 if($taskHasDdr){Copy-Item -LiteralPath (Join-Path $taskRun 'place_route/mini_raw8_geometry_pnr.netlist') -Destination $taskArchive}
 Get-ChildItem (Join-Path $taskRun 'place_route') -File |
  Where-Object {$_.Extension -in @('.prr','.txt')} | Copy-Item -Destination $taskArchive
 $taskRoutedDb=Join-Path $taskArchive 'mini_raw8_geometry_pnr.adf'
 Get-FileHash -LiteralPath $taskRoutedDb | ConvertTo-Json | Set-Content routed_db_hash.json -Encoding utf8
 # Purpose: text-valid PCF is only a candidate. Re-export this exact routed
 # database and prove every requested DDR leaf's actual type and placement
 # before STA/image generation. Old PNR locations cannot satisfy this gate.
 if($taskHasDdr){
  $auditDir=Join-Path $taskRun 'ddr_physical_verification'
  New-Item -ItemType Directory -Path $auditDir | Out-Null
  $savedAuditEnv=@{}
  foreach($name in @('GEOMETRY_AUDIT_DB','GEOMETRY_AUDIT_MAP','GEOMETRY_AUDIT_PCF','GEOMETRY_AUDIT_IMPL')){
   $savedAuditEnv[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
  }
  try {
   $env:GEOMETRY_AUDIT_DB=$taskRoutedDb;$env:GEOMETRY_AUDIT_MAP=$env:GEOMETRY_MAP_DB
   $env:GEOMETRY_AUDIT_PCF=$env:GEOMETRY_MAP_PCF;$env:GEOMETRY_AUDIT_IMPL=$auditDir
   # PDS parses Tcl twice; create provenance here only after native export
   # returns, not as a side effect during native project parsing.
   $physicalInputs=@()
   foreach($pair in @(@('routed_db',$taskRoutedDb),@('map_adf',$env:GEOMETRY_MAP_DB),@('mapped_pcf',$env:GEOMETRY_MAP_PCF),@('inspector',(Join-Path $PSScriptRoot 'inspect_geometry_ddr_placement.tcl')))){
    $physicalInputs+=[pscustomobject]@{role=$pair[0];path=$pair[1];sha256=(Get-FileHash -LiteralPath $pair[1]).Hash}
   }
   $inspectStart=Get-Date
   & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'inspect_geometry_ddr_placement.tcl') -work_dir $auditDir 2>&1 | Tee-Object (Join-Path $auditDir 'native.log')
   if($LASTEXITCODE -or (Select-String (Join-Path $auditDir 'native.log') -Pattern '^E:' -Quiet) -or !(Select-String (Join-Path $auditDir 'native.log') -Pattern GEOMETRY_DDR_PLACEMENT_EXPORTED -Quiet)){throw 'Native DDR placement export failed'}
   $actualPcf=Join-Path $auditDir 'actual_ddr.pcf'
   if(!(Test-Path -LiteralPath $actualPcf) -or (Get-Item -LiteralPath $actualPcf).LastWriteTime -lt $inspectStart){throw 'Missing fresh native DDR placement export'}
   foreach($entry in $physicalInputs){if((Get-FileHash -LiteralPath $entry.path).Hash -ne $entry.sha256){throw 'Physical export input changed'}}
   $physicalInputs+=[pscustomobject]@{role='native_pcf';path=$actualPcf;sha256=(Get-FileHash -LiteralPath $actualPcf).Hash}
   $physicalInputs | Export-Csv -LiteralPath (Join-Path $auditDir 'native_export_manifest.tsv') -Delimiter "`t" -NoTypeInformation -Encoding utf8
  } finally {foreach($name in $savedAuditEnv.Keys){[Environment]::SetEnvironmentVariable($name,$savedAuditEnv[$name],'Process')}}
  & (Join-Path $PSScriptRoot 'verify_geometry_ddr_placement.ps1') -Profile $Profile -AuditJson $taskDdrAudit -NativePcf (Join-Path $auditDir 'actual_ddr.pcf') -NativeNetlist (Join-Path $taskArchive 'mini_raw8_geometry_pnr.netlist') -RoutedDb $taskRoutedDb -MapAdf $env:GEOMETRY_MAP_DB -MappedPcf $env:GEOMETRY_MAP_PCF -OutputPath (Join-Path $taskRun 'ddr_physical_verified.json')
 }
 $taskOldDiagDb=$env:GEOMETRY_DIAG_DB;$taskOldDiagImpl=$env:GEOMETRY_DIAG_IMPL
 try {
  $env:GEOMETRY_DIAG_DB=$taskRoutedDb
  $env:GEOMETRY_DIAG_IMPL=$taskRun
  & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'inspect_geometry_timing.tcl') -work_dir $taskRun 2>&1 | Tee-Object timing.log
  if($LASTEXITCODE -or !(Select-String timing.log -Pattern GEOMETRY_DIAGNOSTIC_STA_COMPLETED -Quiet) -or
   (Select-String timing.log -Pattern '^E:|STA-301[35]|cannot find|matches no|No .* found' -Quiet)){throw 'Checkpoint STA failed'}
 } finally {$env:GEOMETRY_DIAG_DB=$taskOldDiagDb;$env:GEOMETRY_DIAG_IMPL=$taskOldDiagImpl}
 $taskReport=Join-Path $taskRun 'report_timing/mini_raw8_geometry.rtr'
 Copy-Item -LiteralPath $taskReport -Destination (Join-Path $taskRun 'stage_report.rtr')
 $taskTiming=[bool](Select-String -LiteralPath $taskReport -Pattern '^Design Summary\s*:\s*All Constraints Met\.' -Quiet)
 if(!$taskTiming){throw 'Checkpoint routed, but final timing failed'}
 Assert-CheckpointSources
 $env:GEOMETRY_IMPL=$taskRun
 $env:GEOMETRY_PNR_DB=$taskRoutedDb
 $taskDbHash=(Get-FileHash -LiteralPath $env:GEOMETRY_PNR_DB).Hash
 & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'export_geometry_sbit.tcl') -work_dir $taskRun 2>&1 | Tee-Object bitstream.log
 if($LASTEXITCODE -or !(Select-String bitstream.log -Pattern GEOMETRY_EXACT_PNR_IMAGE_GENERATED -Quiet) -or
  (Select-String bitstream.log -Pattern '^E:' -Quiet)){throw 'Checkpoint image export failed'}
 if((Get-FileHash -LiteralPath $env:GEOMETRY_PNR_DB).Hash -ne $taskDbHash){throw 'Routed DB changed during export'}
 Assert-CheckpointSources
 Copy-Item -LiteralPath (Join-Path $taskRun 'generate_bitstream/mini_raw8_geometry.sbit') -Destination $taskRun
 $taskImage=$true
} finally {
 try {Assert-CheckpointSources;$taskUnchanged=$true} catch {$taskUnchanged=$false}
 [ordered]@{native_stage_completed=$taskRouted;timing_constraints_met=$taskTiming;bitstream_generated=$taskImage;source_inputs_unchanged=$taskUnchanged;
  new_placement_seed=$NewPlacementSeed;ddr_profile=$Profile;
  placement_decongestion=$Decongestion;
  programmed=$false;hardware_tested=$false;external_dvp_timing_verified=$false;checkpoint=$taskCheckpoint} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 foreach($taskName in $taskOld.Keys){[Environment]::SetEnvironmentVariable($taskName,$taskOld[$taskName],'Process')}
 Pop-Location
}
Write-Output "GEOMETRY_RESUMED_BUILD_PASS $taskRun"
