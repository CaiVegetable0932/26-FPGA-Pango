# Purpose: resume an unchanged native-free map/PCF with ONLY reviewed routing
# priorities. Zero seed consumes checkpoint PLC; positive seed places anew.
# Never edits original manifests/constraints/checkpoints or accesses hardware.
# Exporter integration remains external: check_geometry_priority_override.ps1
# -Run <run> checks provenance; normal exporter/finalizer must still sign off.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Checkpoint,
 [ValidateRange(0,1000)][int]$NewPlacementSeed=0,
 [ValidateRange(0,9)][int]$Decongestion=3,
 [Parameter(Mandatory=$true)][string]$PriorityRcf,
 [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$taskChecker=Join-Path $PSScriptRoot 'check_geometry_priority_override.ps1'
. $taskChecker
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskCp=Get-PriorityCheckpoint $Checkpoint $NewPlacementSeed
$taskCandidate=Assert-PriorityInside $PriorityRcf (Join-Path $taskFpga 'build')
Assert-PriorityRcf (Join-Path $taskFpga 'constraints/mini_raw8_dual/geometry_priority.rcf') 8
Assert-PriorityRcf $taskCandidate
$taskShell=Get-PriorityPath (Join-Path $PdsHome 'bin/pds_shell.exe')
$taskRun=Join-Path $taskFpga ('build/mini_raw8_geometry/priority_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $taskRun 'routing')) | Out-Null
Copy-Item -LiteralPath $taskCandidate -Destination (Join-Path $taskRun 'routing/geometry_priority.rcf')
Copy-Item -LiteralPath $taskCp.manifest -Destination (Join-Path $taskRun 'source_manifest.json')
$taskState=[pscustomobject]@{schema_version=1;override_only=$true;timing_budget_changed=$false;
 source_inputs_unchanged=$true;release_qualified=$false;run=$taskRun;checkpoint=$taskCp.checkpoint;
 candidate_rcf=$taskCandidate;new_placement_seed=$NewPlacementSeed;decongestion=$Decongestion;
 stages=@();bindings=@();native_priority_route=$null}
$taskPinned=@(Get-PriorityBindings $taskState)
$taskNativeShellHash=Get-PriorityHash $taskShell
$taskOld=@{}
foreach($name in @('PANGO_LICENSE_FILE','GEOMETRY_PRIORITY_RUN','GEOMETRY_PRIORITY_STAGE',
 'GEOMETRY_MAP_DB','GEOMETRY_MAP_PCF','GEOMETRY_PLACE_DB','GEOMETRY_NEW_SEED',
 'GEOMETRY_DECONGESTION','GEOMETRY_PNR_DB')){$taskOld[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$taskRouted=$false; $taskTiming=$false; $taskImage=$false; $taskUnchanged=$false; $taskGate=$false

function Assert-PriorityPinned {
    # Immutable in-memory hashes prevent a changed file being rebaselined
    # when appending a new actual native project to on-disk evidence.
    foreach($entry in $taskPinned){if((Get-PriorityHash $entry.path) -ine $entry.sha256){throw "Pinned input drift: $($entry.role)"}}
    if((Get-PriorityHash $taskShell) -ine $taskNativeShellHash){throw 'Native executable changed'}
    $null=Get-PriorityCheckpoint $taskCp.checkpoint $NewPlacementSeed
}
function Save-PriorityStage([string]$Stage) {
    # Append fresh native output only after independently checking its actual
    # constraints/options. Existing evidence hashes remain pinned throughout.
    Assert-PriorityPinned
    $project=Join-Path $taskRun ('geometry_priority_'+$Stage+'.pds')
    Assert-PriorityProject $project $taskState $Stage
    if($Stage -eq 'pnr'){$taskState.native_priority_route=Get-PriorityRouteProof $taskRun}
    $taskState.stages=@($taskState.stages)+@($Stage)
    $taskState.bindings=@(Get-PriorityBindings $taskState)
    $taskState.bindings | ForEach-Object {[pscustomobject]@{Algorithm='SHA256';Hash=$_.sha256;Path=$_.path}} |
      ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $taskRun 'checkpoint_hashes.json') -Encoding utf8
    $taskState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $taskRun 'priority_override.json') -Encoding utf8
    # Internal preflight permits configure-only evidence. The public exporter
    # API additionally requires completed PNR and the eleven-net native log.
    $null=Assert-PriorityAudit (Join-Path $taskRun 'priority_override.json')
    $script:taskPinned=@($taskState.bindings)
}
function Invoke-PriorityNative([string]$Stage) {
    # Stage names are independent native projects in one implementation dir;
    # later commands cannot overwrite the PNR project's evidence or hash.
    Assert-PriorityPinned
    if(@($taskState.stages).Count){$null=Assert-PriorityAudit (Join-Path $taskRun 'priority_override.json')}
    $env:GEOMETRY_PRIORITY_STAGE=$Stage
    $project=Join-Path $taskRun ('geometry_priority_'+$Stage+'.pds')
    if(Test-Path -LiteralPath $project){throw 'Refusing to overwrite native stage evidence'}
    $log=Join-Path $taskRun ($Stage+'.log')
    & $taskShell -file (Join-Path $PSScriptRoot 'resume_geometry_priority_route.tcl') -work_dir $taskRun -project_name ('geometry_priority_'+$Stage) 2>&1 | Tee-Object -FilePath $log
    $code=$LASTEXITCODE
    Assert-PriorityPinned
    Assert-PriorityNativeDiagnostics $log
    if($code -ne 0 -or !(Select-String -LiteralPath $log -Pattern ('^GEOMETRY_PRIORITY_STAGE_CONFIGURED '+$Stage+'\s*$') -Quiet) -or
      (Select-String -LiteralPath $log -Pattern '^E:|STA-301[35]|cannot find|matches no|No .* found' -Quiet)){throw "Native $Stage failed (exit $code)"}
}
Push-Location $taskRun
try {
    if(!$env:PANGO_LICENSE_FILE){$env:PANGO_LICENSE_FILE=[Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','User')}
    $env:GEOMETRY_PRIORITY_RUN=$taskRun
    $env:GEOMETRY_MAP_DB=$taskCp.map; $env:GEOMETRY_MAP_PCF=$taskCp.pcf
    $env:GEOMETRY_PLACE_DB=$taskCp.plc
    $env:GEOMETRY_NEW_SEED=[string]$NewPlacementSeed; $env:GEOMETRY_DECONGESTION=[string]$Decongestion
    Invoke-PriorityNative configure
    Save-PriorityStage configure
    Invoke-PriorityNative pnr
    # Preserve the exact finished DB before separate STA/SBIT invocations.
    $routed=Get-PriorityPath (Join-Path $taskRun 'place_route/mini_raw8_geometry_pnr.adf')
    $snapshot=Join-Path $taskRun 'routed_snapshot'
    [IO.Directory]::CreateDirectory($snapshot) | Out-Null
    Copy-Item -LiteralPath $routed -Destination $snapshot
    $env:GEOMETRY_PNR_DB=Join-Path $snapshot 'mini_raw8_geometry_pnr.adf'
    if((Get-PriorityHash $routed) -ine (Get-PriorityHash $env:GEOMETRY_PNR_DB)){throw 'PNR snapshot mismatch'}
    Get-FileHash -LiteralPath $env:GEOMETRY_PNR_DB -Algorithm SHA256 | ConvertTo-Json |
      Set-Content -LiteralPath (Join-Path $taskRun 'routed_db_hash.json') -Encoding utf8
    $taskRouted=$true
    Save-PriorityStage pnr
    try {Invoke-PriorityNative sta} finally {
        $report=Join-Path $taskRun 'report_timing/mini_raw8_geometry.rtr'
        if(Test-Path -LiteralPath $report){Copy-Item -LiteralPath $report -Destination (Join-Path $taskRun 'stage_report.rtr')}
    }
    Save-PriorityStage sta
    # Preserve original runner STA->SBIT gate; full release finalization remains
    # the existing exporter's responsibility, never a physical-gate assertion.
    $taskTiming=[bool](Select-String -LiteralPath $report -Pattern '^Design Summary\s*:\s*All Constraints Met\.' -Quiet)
    if(!$taskTiming){throw 'Final native min/max STA failed'}
    Invoke-PriorityNative sbit
    Save-PriorityStage sbit
    $image=Get-PriorityPath (Join-Path $taskRun 'generate_bitstream/mini_raw8_geometry.sbit')
    $null=Get-PriorityHash $image
    Copy-Item -LiteralPath $image -Destination $taskRun
    $taskImage=$true
} finally {
    # Even failed runs retain honest state. A physical gate failure cannot be
    # relabelled successful merely because routing or image output exists.
    try {Assert-PriorityPinned; $taskUnchanged=$true; $null=& $taskChecker -Run $taskRun; $taskGate=$true} catch {$taskGate=$false}
    [ordered]@{native_stage_completed=$taskRouted;timing_constraints_met=$taskTiming;
      bitstream_generated=($taskImage -and $taskGate);source_inputs_unchanged=$taskUnchanged;
      priority_override_valid=$taskGate;new_placement_seed=$NewPlacementSeed;
      placement_decongestion=$Decongestion;checkpoint=$taskCp.checkpoint;
      programmed=$false;hardware_tested=$false;external_dvp_timing_verified=$false} |
      ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRun 'result.json') -Encoding utf8
    foreach($name in $taskOld.Keys){[Environment]::SetEnvironmentVariable($name,$taskOld[$name],'Process')}
    Pop-Location
}
if(!$taskGate){throw 'Final priority provenance gate failed'}
Write-Output "GEOMETRY_PRIORITY_RESUMED_BUILD_PASS $taskRun"
