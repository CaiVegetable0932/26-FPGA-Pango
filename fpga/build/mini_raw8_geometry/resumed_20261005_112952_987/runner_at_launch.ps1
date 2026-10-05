# Purpose: verify checkpoint provenance, resume native routing into a fresh
# directory, and export the exact DB only after passing final min/max timing.
# It never opens board devices. A larger execution limit is not a timing waiver.
param([Parameter(Mandatory=$true)][string]$Checkpoint,
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskCheckpoint=(Resolve-Path -LiteralPath $Checkpoint).Path
$taskBuild=[IO.Path]::GetFullPath((Join-Path $taskFpga 'build'))
if(!$taskCheckpoint.StartsWith($taskBuild+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Checkpoint must belong to fpga/build'}
$taskSources=Get-Content (Join-Path $taskCheckpoint 'source_manifest.json') -Raw | ConvertFrom-Json
function Assert-CheckpointSources {
 # Both preflight and final export must match the checkpoint's source inputs.
 foreach($taskSource in $taskSources){
  if((Get-FileHash -LiteralPath $taskSource.path).Hash -ne $taskSource.sha256){throw "Checkpoint source changed: $($taskSource.path)"}
 }
}
Assert-CheckpointSources
$taskRun=Join-Path $taskFpga ('build/mini_raw8_geometry/resumed_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
Copy-Item -LiteralPath (Join-Path $taskCheckpoint 'source_manifest.json') -Destination $taskRun
$taskOld=@{}
foreach($taskName in @('PANGO_LICENSE_FILE','GEOMETRY_MAP_DB','GEOMETRY_PLACE_DB','GEOMETRY_RESUME_IMPL','GEOMETRY_IMPL','GEOMETRY_PNR_DB')){
 $taskOld[$taskName]=[Environment]::GetEnvironmentVariable($taskName,'Process')
}
$taskTiming=$false;$taskImage=$false;$taskUnchanged=$false
Push-Location $taskRun
try {
 if(!$env:PANGO_LICENSE_FILE){$env:PANGO_LICENSE_FILE=[Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','User')}
 $env:GEOMETRY_MAP_DB=Join-Path $taskCheckpoint 'mini_raw8_geometry_map.adf'
 $env:GEOMETRY_PLACE_DB=Join-Path $taskCheckpoint 'mini_raw8_geometry_plc.adf'
 $env:GEOMETRY_RESUME_IMPL=$taskRun
 # Preserve hashes of the exact checkpoint and runner used for this attempt.
 @($env:GEOMETRY_MAP_DB,$env:GEOMETRY_PLACE_DB,$PSCommandPath,(Join-Path $PSScriptRoot 'resume_geometry_route.tcl')) |
  ForEach-Object {Get-FileHash -LiteralPath $_} | ConvertTo-Json | Set-Content checkpoint_hashes.json -Encoding utf8
 & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'resume_geometry_route.tcl') -work_dir $taskRun 2>&1 | Tee-Object route.log
 if($LASTEXITCODE -or !(Select-String route.log -Pattern GEOMETRY_CHECKPOINT_PROJECT_CONFIGURED -Quiet) -or
  (Select-String route.log -Pattern '^E:|STA-301[35]|cannot find|matches no|No .* found' -Quiet)){throw 'Checkpoint native flow failed'}
 # Native Tcl pnr sets action options; explicitly run the generated project.
 $taskProject=Join-Path $taskRun 'resume_geometry_route.pds'
 & "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskRun -run pnr 2>&1 | Tee-Object pnr.log
 if($LASTEXITCODE -or (Select-String pnr.log -Pattern '^E:' -Quiet)){throw 'Checkpoint routing failed'}
 $taskOldDiagDb=$env:GEOMETRY_DIAG_DB;$taskOldDiagImpl=$env:GEOMETRY_DIAG_IMPL
 try {
  $env:GEOMETRY_DIAG_DB=Join-Path $taskRun 'place_route/mini_raw8_geometry_pnr.adf'
  $env:GEOMETRY_DIAG_IMPL=$taskRun
  & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'inspect_geometry_timing.tcl') -work_dir $taskRun 2>&1 | Tee-Object timing.log
  if($LASTEXITCODE -or !(Select-String timing.log -Pattern GEOMETRY_DIAGNOSTIC_STA_COMPLETED -Quiet) -or
   (Select-String timing.log -Pattern '^E:|STA-301[35]|cannot find|matches no|No .* found' -Quiet)){throw 'Checkpoint STA failed'}
 } finally {$env:GEOMETRY_DIAG_DB=$taskOldDiagDb;$env:GEOMETRY_DIAG_IMPL=$taskOldDiagImpl}
 $taskReport=Join-Path $taskRun 'report_timing/mini_raw8_geometry.rtr'
 $taskTiming=[bool](Select-String -LiteralPath $taskReport -Pattern '^Design Summary\s*:\s*All Constraints Met\.' -Quiet)
 if(!$taskTiming){throw 'Checkpoint routed, but final timing failed'}
 Assert-CheckpointSources
 $env:GEOMETRY_IMPL=$taskRun
 $env:GEOMETRY_PNR_DB=Join-Path $taskRun 'place_route/mini_raw8_geometry_pnr.adf'
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
 [ordered]@{timing_constraints_met=$taskTiming;bitstream_generated=$taskImage;source_inputs_unchanged=$taskUnchanged;
  programmed=$false;hardware_tested=$false;external_dvp_timing_verified=$false;checkpoint=$taskCheckpoint} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 foreach($taskName in $taskOld.Keys){[Environment]::SetEnvironmentVariable($taskName,$taskOld[$taskName],'Process')}
 Pop-Location
}
Write-Output "GEOMETRY_RESUMED_BUILD_PASS $taskRun"
