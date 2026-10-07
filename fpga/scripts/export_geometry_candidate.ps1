# Purpose: publish an offline geometry bring-up package only after current
# source hashes, final routed STA and functional regressions pass. Converts
# SBIT to XT25F128 SFC with an existing project runtime; never opens hardware.
param([Parameter(Mandatory=$true)][string]$Run,
 [Parameter(Mandatory=$true)][string]$BoardSimulation,
 [Parameter(Mandatory=$true)][string]$ChainSimulation,
 [Parameter(Mandatory=$true)][string]$Equivalence,
 [Parameter(Mandatory=$true)][string]$McuSimulation,
 [Parameter(Mandatory=$true)][string]$QueueSimulation,
 [Parameter(Mandatory=$true)][string]$DecoderEquivalence,
 [Parameter(Mandatory=$true)][string]$CacheEquivalence,
 [Parameter(Mandatory=$true)][string]$SnapshotEquivalence,
 [Parameter(Mandatory=$true)][string]$PacketSimulation,
 [Parameter(Mandatory=$true)][string]$OriginalSimulation,
 [Parameter(Mandatory=$true)][string]$MarkerSimulation,
 [Parameter(Mandatory=$true)][string]$WindowSimulation,
 [Parameter(Mandatory=$true)][string]$MapSimulation,
 [Parameter(Mandatory=$true)][string]$WriterSimulation,
 [Parameter(Mandatory=$true)][string]$PredecodeSimulation,
 [Parameter(Mandatory=$true)][string]$ViewPredecodeSimulation,
 [Parameter(Mandatory=$true)][string]$DividerSimulation,
 [Parameter(Mandatory=$true)][string]$CoreReadSimulation,
 [Parameter(Mandatory=$true)][string]$ReplyEquivalence,
 [Parameter(Mandatory=$true)][string]$ResourceEquivalence,
 [Parameter(Mandatory=$true)][string]$CacheTimingEquivalence,
 [Parameter(Mandatory=$true)][string]$BootEpochEquivalence,
 [Parameter(Mandatory=$true)][string]$CfgRuntime)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskBuild=[IO.Path]::GetFullPath((Join-Path $taskFpga 'build'))
function Resolve-Build([string]$Path) {
 # Evidence must be project-owned, not arbitrary files or official examples.
 $resolved=(Resolve-Path -LiteralPath $Path).Path
 if(!$resolved.StartsWith($taskBuild+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
  throw 'Evidence must be inside this FPGA build directory'
 }
 return $resolved
}
function Assert-Hashes($Entries) {
 # Purpose: an empty or malformed manifest must not silently satisfy a gate.
 if(!@($Entries).Count){throw 'Empty evidence hash manifest'}
 foreach($entry in $Entries){
  if(!$entry.path -or $entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Malformed evidence hash record'}
  if((Get-FileHash -LiteralPath $entry.path).Hash -ne $entry.sha256){throw "Stale input: $($entry.path)"}
 }
}
function Assert-Log([string]$Path,[string]$Pass) {
 $body=Get-Content -LiteralPath $Path -Raw
 if($body -notmatch $Pass -or $body -match '\*\* (Fatal|Error)|GEOMETRY_\w*(FAIL|TIMEOUT)|EFFICIENCY_\w*(FAIL|TIMEOUT)|MCU_PROTOCOL_FAIL|MCU_DECODER_FAIL|QUEUE_RAM_\w*FAIL'){
  throw "Regression did not pass: $Path"
 }
}
# Purpose: bind the required saved resource proof and its checker before any
# native finalization. CheckPublishedEvidence validates exact typed saved data
# against a fresh read-only corpus check; freezing both files closes copy races.
function Assert-ResourceEquivalence([string]$Directory,[string]$Checker,[string]$TimingDirectory) {
 $evidence=Join-Path $Directory 'resource_evidence.json'
 $manifest=Join-Path $Directory 'resource_manifest.json'
 $hashes=@($evidence,$manifest,$Checker | ForEach-Object {
  [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
 })
 $check=& $Checker -WorkspaceRoot (Split-Path $taskFpga -Parent) -EvidenceDirectory $Directory -CacheTimingEquivalence $TimingDirectory -ValidateOnly -CheckPublishedEvidence
 Assert-Hashes $hashes
 return [pscustomobject]@{directory=$Directory;evidence=$evidence;manifest=$manifest;hashes=$hashes;check=$check}
}
# Purpose: mandatory exact cache timing proof is independently frozen before
# finalization. All checked source/log/metadata bytes and the validator itself
# join the publication hash chain; the result is recomputed from reviewed pins.
function Assert-CacheTimingEquivalence([string]$Directory,[string]$Checker) {
 $taskRoot=Split-Path $taskFpga -Parent
 $checkerHash=(Get-FileHash -LiteralPath $Checker).Hash
 # Independent reviewed literal prevents substituting a truthy fake checker.
 if($checkerHash -cne '00AB65C38870AFD5B239C30B01716F40F51CA61C282E57F56D5CB091C843EBA5'){
  throw 'Unreviewed parallel-valid checker'
 }
 $check=& $Checker -WorkspaceRoot $taskRoot -EvidenceDirectory $Directory -CheckPublishedEvidence
 if($check.passed -isnot [bool] -or !$check.passed -or $check.schema_version -cne 'cache-valid-parallel-evidence/v1'){
  throw 'Cache parallel-valid proof failed'
 }
 $hashes=@([pscustomobject]@{path=$Checker;sha256=$checkerHash},
  [pscustomobject]@{path=(Join-Path $Directory 'cache_valid_parallel_evidence.json');sha256=(Get-FileHash -LiteralPath (Join-Path $Directory 'cache_valid_parallel_evidence.json')).Hash})
 $hashes+=@($check.files_after|ForEach-Object {[pscustomobject]@{path=(Join-Path $taskRoot $_.path);sha256=$_.sha256}})
 Assert-Hashes $hashes
 return [pscustomobject]@{directory=$Directory;hashes=$hashes;check=$check}
}
# Purpose: the physical top now specializes epoch flushing using the immutable
# boot/reset contract. Generic UART tests cannot prove this board-only premise.
# Require its separately frozen real-UART proof before native finalization, and
# bind the checker itself plus every checked source/log against packaging drift.
function Assert-BootEpochEquivalence([string]$Directory,[string]$Checker) {
 $checkerHash=(Get-FileHash -LiteralPath $Checker).Hash
 $check=& $Checker -WorkspaceRoot (Split-Path $taskFpga -Parent) -EvidenceDirectory $Directory
 if($check.passed -isnot [bool] -or !$check.passed -or !@($check.inputs).Count){throw 'Boot epoch contract proof failed'}
 Assert-Hashes $check.inputs
 # Preserve one checker binding even if the validator also returns its own
 # checksum; all returned records have already been checked above.
 $hashes=@([pscustomobject]@{path=$Checker;sha256=$checkerHash})+@($check.inputs | Where-Object {
  [IO.Path]::GetFullPath($_.path) -ne [IO.Path]::GetFullPath($Checker)
 })
 Assert-Hashes $hashes
 return [pscustomobject]@{directory=$Directory;hashes=$hashes;check=$check}
}
$taskRun=Resolve-Build $Run
$taskTiming=Resolve-Build $CacheTimingEquivalence
$taskTimingChecker=Join-Path $PSScriptRoot 'check_cache_valid_parallel_evidence.ps1'
$taskTimingCheck=Assert-CacheTimingEquivalence $taskTiming $taskTimingChecker
$taskResource=Resolve-Build $ResourceEquivalence
$taskResourceChecker=Join-Path $PSScriptRoot 'check_geometry_resource_evidence.ps1'
$taskResourceCheck=Assert-ResourceEquivalence $taskResource $taskResourceChecker $taskTiming
$taskBoot=Resolve-Build $BootEpochEquivalence
$taskBootChecker=Join-Path $PSScriptRoot 'check_geometry_boot_epoch_evidence.ps1'
$taskBootCheck=Assert-BootEpochEquivalence $taskBoot $taskBootChecker
# Purpose: a merged post-map PCF is not proof that locations were honored.
# Require the exact new routed DB's independently exported requested placement
# and GOP-type evidence; preserve input hashes through packaging.
$taskPhysicalEvidence=Join-Path $taskRun 'ddr_physical_verified.json'
if(Test-Path -LiteralPath (Join-Path $taskRun 'ddr_placement_audit.json')){
 if(!(Test-Path -LiteralPath $taskPhysicalEvidence)){throw 'Missing native DDR placement verification'}
 $physical=Get-Content -LiteralPath $taskPhysicalEvidence -Raw | ConvertFrom-Json
 if(!$physical.passed -or !$physical.inputs){throw 'Native DDR placement verification failed'}
 Assert-Hashes $physical.inputs
}
# Refuse release if PDS replaced the board's DDR/HDMI priorities with a
# second RCF. A checkpoint retry has its own native project: audit that
# actual PNR project, not only the shared original project's constraint list.
$taskResumeProject=Join-Path $taskRun 'resume_geometry_route.pds'
if(Test-Path -LiteralPath $taskResumeProject){
 & (Join-Path $PSScriptRoot 'check_geometry_route_constraints.ps1') -Project $taskResumeProject
 # The native retry binds both its runner and mapped/placed input database.
 # Recheck those records before packaging; never silently reuse a modified
 # physical checkpoint even if the RTL-only source manifest still matches.
 foreach($taskEvidenceName in @('checkpoint_hashes.json','routed_db_hash.json')){
  foreach($taskHashRecord in (Get-Content (Join-Path $taskRun $taskEvidenceName) -Raw | ConvertFrom-Json)){
   if((Get-FileHash -LiteralPath $taskHashRecord.Path).Hash -ne $taskHashRecord.Hash){
    throw "Changed physical provenance: $($taskHashRecord.Path)"
   }
  }
 }
}else{
 & (Join-Path $PSScriptRoot 'check_geometry_route_constraints.ps1')
}
$taskBoard=Resolve-Build $BoardSimulation
$taskChain=Resolve-Build $ChainSimulation
$taskEq=Resolve-Build $Equivalence
$taskMcu=Resolve-Build $McuSimulation
$taskQueue=Resolve-Build $QueueSimulation
$taskDecoder=Resolve-Build $DecoderEquivalence
$taskCache=Resolve-Build $CacheEquivalence
$taskSnapshot=Resolve-Build $SnapshotEquivalence
$taskPacket=Resolve-Build $PacketSimulation
$taskOriginal=Resolve-Build $OriginalSimulation
$taskMarkers=Resolve-Build $MarkerSimulation
$taskWindow=Resolve-Build $WindowSimulation
$taskMap=Resolve-Build $MapSimulation
$taskWriter=Resolve-Build $WriterSimulation
$taskPredecode=Resolve-Build $PredecodeSimulation
$taskViewPredecode=Resolve-Build $ViewPredecodeSimulation
$taskDivider=Resolve-Build $DividerSimulation
$taskCoreRead=Resolve-Build $CoreReadSimulation
$taskReply=Resolve-Build $ReplyEquivalence
# Purpose: the parallel reply tail must match its frozen cycle-miter candidate
# as well as passing the current-production UART and full-board tests below.
$taskReplyCheck=& (Join-Path $PSScriptRoot 'check_mcu_reply_evidence.ps1') -EvidenceDirectory $taskReply
$taskResult=Get-Content (Join-Path $taskRun 'result.json') -Raw | ConvertFrom-Json
if(!$taskResult.native_stage_completed -or !$taskResult.timing_constraints_met -or
 !$taskResult.source_inputs_unchanged -or !$taskResult.bitstream_generated){throw 'No fresh timing-qualified bitstream'}
$taskReport=Join-Path $taskRun 'stage_report.rtr'
if(!(Select-String -LiteralPath $taskReport -Pattern '^Design Summary\s*:\s*All Constraints Met\.' -Quiet)){
 throw 'Final min/max timing report failed'
}
$taskInputs=Get-Content (Join-Path $taskRun 'source_manifest.json') -Raw | ConvertFrom-Json
Assert-Hashes $taskInputs
foreach($taskPath in @($taskBoard,$taskChain,$taskEq,$taskQueue,$taskDecoder,$taskCache,$taskSnapshot)){
 Assert-Hashes (Get-Content (Join-Path $taskPath 'sources.json') -Raw | ConvertFrom-Json)
}
Assert-Log (Join-Path $taskBoard 'simulation.log') 'GEOMETRY_BOARD_PASS'
foreach($taskTop in @('lens','pipeline','uart','pool')){
 Assert-Log (Join-Path $taskChain "tb_geometry_$taskTop.log") 'GEOMETRY_\w+_PASS'
}
Assert-Log (Join-Path $taskChain 'brown.log') 'GEOMETRY_LENS_PASS model=1'
Assert-Log (Join-Path $taskChain 'tb_geometry.log') 'GEOMETRY_PASS'
foreach($taskTop in @('config','sampler','map','tone')){
 Assert-Log (Join-Path $taskEq "tb_${taskTop}_efficiency.log") 'EFFICIENCY_\w+_PASS'
}
$taskMcuResult=Get-Content (Join-Path $taskMcu 'result.json') -Raw | ConvertFrom-Json
if(!$taskMcuResult.simulation_passed){throw 'MCU regression failed'}
Assert-Hashes $taskMcuResult.source_sha256
Assert-Log (Join-Path $taskMcu 'full.log') 'MCU_PROTOCOL_PASS'
Assert-Log (Join-Path $taskMcu 'clock125.log') 'MCU_PROTOCOL_PASS'
# Purpose: the RAM queue and parallel reply decoder are new timing-critical
# implementations. Require current-source cycle/response comparison evidence
# as well as physical UART tests; do not accept experimental/stale RTL tests.
if(!(Get-Content (Join-Path $taskQueue 'result.json') -Raw | ConvertFrom-Json).equivalence_passed -or
 !(Get-Content (Join-Path $taskDecoder 'result.json') -Raw | ConvertFrom-Json).equivalence_passed){
 throw 'Queue/decoder equivalence failed'
}
Assert-Log (Join-Path $taskQueue 'simulation.log') 'QUEUE_RAM_EQUIVALENCE_PASS'
foreach($taskGeom in @(0,1)){foreach($taskFeatures in 0..7){
 Assert-Log (Join-Path $taskDecoder "geometry_${taskGeom}_features_${taskFeatures}.log") 'MCU_DECODER_EQUIVALENCE_PASS'
}}
# Purpose: tag-prefetch and ungated snapshot flops need current cycle-miter
# evidence. The fixed header mux additionally requires real RTL bytes accepted
# by the host decoder; no old unmodified-source evidence may satisfy this gate.
foreach($taskPath in @($taskCache,$taskSnapshot)){
 if(!(Get-Content (Join-Path $taskPath 'result.json') -Raw | ConvertFrom-Json).equivalence_passed){
  throw 'Structural cycle equivalence failed'
 }
}
Assert-Log (Join-Path $taskCache 'simulation.log') 'CACHE_TIMING_EQUIVALENCE_PASS'
Assert-Log (Join-Path $taskSnapshot 'simulation.log') 'SNAPSHOT_TIMING_PASS'
Assert-Hashes (Get-Content (Join-Path $taskPacket 'source_manifest.json') -Raw | ConvertFrom-Json)
Assert-Log (Join-Path $taskPacket 'simulation.log') 'PRAW_PACKETIZER_PASS'
$taskPacketResult=Get-Content (Join-Path $taskPacket 'result.json') -Raw | ConvertFrom-Json
if(!$taskPacketResult.passed -or !$taskPacketResult.full_1080p_raw){throw 'Missing complete RAW8 packet interoperability evidence'}
# Purpose: this release contains a spatial map, multi-port window cache and
# queued result writer, not the legacy scalar implementation. Require both
# full-frame modes and their own current-source regressions before packaging.
foreach($taskPath in @($taskOriginal,$taskWindow,$taskMap,$taskWriter)){
 Assert-Hashes (Get-Content (Join-Path $taskPath 'sources.json') -Raw | ConvertFrom-Json)
}
# Marker evidence additionally binds the authoritative host definitions and
# vector generator, and records source-set changes across the simulation.
$taskMarkerInputs=Get-Content (Join-Path $taskMarkers 'sources.json') -Raw | ConvertFrom-Json
$taskMarkerVerification=Get-Content (Join-Path $taskMarkers 'sources.verification.json') -Raw | ConvertFrom-Json
if(!$taskMarkerInputs.captured_before_vector_generation -or !$taskMarkerVerification.passed -or
 $taskMarkerInputs.source_count -lt 1){throw 'Missing before/after marker source evidence'}
Assert-Hashes $taskMarkerInputs.files
Assert-Log (Join-Path $taskBoard 'simulation.log') 'GEOMETRY_BOARD_PASS original=0 fisheye=1'
Assert-Log (Join-Path $taskOriginal 'simulation.log') 'GEOMETRY_BOARD_PASS original=1 fisheye=0'
foreach($taskTop in @('markers','view','view_uart','marker_overlay')){
 Assert-Log (Join-Path $taskMarkers "tb_geometry_$taskTop.log") 'GEOMETRY_(MARKERS|VIEW|VIEW_UART|MARKER_OVERLAY)_PASS'
}
Assert-Log (Join-Path $taskMarkers 'view_uart_disabled.log') 'GEOMETRY_VIEW_UART_PASS'
$taskWindowResult=Get-Content (Join-Path $taskWindow 'result.json') -Raw | ConvertFrom-Json
if(!$taskWindowResult.passed -or 1024 -notin $taskWindowResult.cache_words){throw 'Missing production cache regression'}
# Purpose: require every tested cache size and boundary/stride workload; an
# empty wildcard must never count as passing production-cache validation.
foreach($taskCacheWords in @(64,256,1024)){
 foreach($taskCase in @('32x8_stride32','32x8_stride2048','70x19_stride128','1920x1080_stride2048')){
  Assert-Log (Join-Path $taskWindow "window_${taskCase}_cache${taskCacheWords}_pixels4096.log") 'WINDOW_EQUIVALENCE_PASS'
 }
 Assert-Log (Join-Path $taskWindow "window_1920x1080_stride2048_cache${taskCacheWords}_pixels30720.log") 'WINDOW_EQUIVALENCE_PASS'
}
foreach($taskModel in @(0,1,2)){Assert-Log (Join-Path $taskMap "model$taskModel.log") 'MAP_STREAM_PASS'}
Assert-Log (Join-Path $taskWriter 'case0.log') 'STREAM_WRITER_PASS'
Assert-Log (Join-Path $taskWriter 'case1.log') 'STREAM_WRITER_BAD_FENCE_PASS'
# Purpose: the board opts into address-only READ predecode. Require both
# legacy combinational equivalence and real UART stability/fresh-snapshot
# checks; a passing generic config-bank test alone cannot cover this mode.
$taskPredecodeInputs=Get-Content (Join-Path $taskPredecode 'sources.json') -Raw | ConvertFrom-Json
Assert-Hashes $taskPredecodeInputs.files
if(!(Get-Content (Join-Path $taskPredecode 'sources.verification.json') -Raw | ConvertFrom-Json).passed){
 throw 'READ predecode inputs changed during regression'
}
Assert-Log (Join-Path $taskPredecode 'default_equivalence.log') 'CONFIG_PREDECODE_PASS'
Assert-Log (Join-Path $taskPredecode 'uart_default.log') 'CONFIG_READ_UART_PASS'
Assert-Log (Join-Path $taskPredecode 'uart_125mhz.log') 'CONFIG_READ_UART_PASS'
# Purpose: the production metadata address predecode must retain live display
# data, and the marker divider CE removal must preserve every output cycle.
# Require the dedicated current-source miters in addition to full-board tests.
foreach($taskPath in @($taskViewPredecode,$taskDivider)){
 Assert-Hashes (Get-Content (Join-Path $taskPath 'sources.json') -Raw | ConvertFrom-Json)
 if(!(Get-Content (Join-Path $taskPath 'result.json') -Raw | ConvertFrom-Json).passed){
  throw 'View decoder/divider timing equivalence failed'
 }
}
Assert-Log (Join-Path $taskViewPredecode 'simulation.log') 'GEOMETRY_VIEW_PASS.*predecode_checks=.*fresh_reads='
foreach($taskSeed in @(20261007,1,987654321)){
 Assert-Log (Join-Path $taskDivider "seed_$taskSeed.log") 'MARKER_DIVIDER_PASS'
}
# This UART-to-production-core test complements the static decoder miter:
# it covers CRC-edge current data, all bank-2 words, bank-1 status and 0x35.
# Forced storage fixtures make it control-path evidence, never a video test.
Assert-Hashes (Get-Content (Join-Path $taskCoreRead 'sources.before.json') -Raw | ConvertFrom-Json)
$taskCoreReadResult=Get-Content (Join-Path $taskCoreRead 'result.json') -Raw | ConvertFrom-Json
if(!$taskCoreReadResult.passed -or !$taskCoreReadResult.source_inputs_unchanged){throw 'Core UART predecode regression failed'}
foreach($taskLog in @('uart_125mhz_fast.log','uart_125mhz_115200.log')){
 Assert-Log (Join-Path $taskCoreRead $taskLog) 'CORE_READ_UART_PASS'
}
# Purpose: re-run final STA and image export from the SAME routed DB in a
# fresh directory, binding the scripts/report/image at generation time. The
# earlier unbound run-level SBIT is not used for the released payload. There is
# deliberately no cached-evidence input: every publication runs the finalizer,
# which binds fresh native STA and SBIT to one frozen copy of this routed DB.
$taskFinalized=& (Join-Path $PSScriptRoot 'finalize_geometry_evidence.ps1') -Run $taskRun
$taskFinalEvidence=Resolve-Build $taskFinalized.evidence_path
$taskFinal=Get-Content -LiteralPath $taskFinalEvidence -Raw | ConvertFrom-Json
foreach($taskFlag in @('passed','timing_constraints_met','multi_corner_min_max_verified')){
 if($taskFinal.$taskFlag -isnot [bool] -or !$taskFinal.$taskFlag){throw "Invalid final generation flag: $taskFlag"}
}
if($taskFinal.schema_version -ne 1 -or
 [IO.Path]::GetFullPath($taskFinal.run) -ne $taskRun){throw 'Invalid final generation evidence'}
Assert-Hashes $taskFinal.inputs
Assert-Hashes $taskFinal.outputs
$taskFinalDb=@($taskFinal.inputs | Where-Object {$_.role -eq 'routed_db'})
$taskOriginalDb=@($taskFinal.inputs | Where-Object {$_.role -eq 'original_routed_db'})
$taskFinalSbit=@($taskFinal.outputs | Where-Object {$_.role -eq 'sbit'})
$taskFinalReport=@($taskFinal.outputs | Where-Object {$_.role -eq 'timing_report'})
# The finalizer freezes an identical copy of the routed DB and constraints.
# Require that copy's hash to match the original run, not its different path.
if($taskFinalDb.Count -ne 1 -or $taskOriginalDb.Count -ne 1 -or
 $taskFinalSbit.Count -ne 1 -or $taskFinalReport.Count -ne 1 -or
 $taskFinalDb[0].sha256 -ne $taskOriginalDb[0].sha256 -or
 [IO.Path]::GetFullPath($taskOriginalDb[0].path) -ne [IO.Path]::GetFullPath((Join-Path $taskRun 'routed_snapshot/mini_raw8_geometry_pnr.adf'))){
 throw 'Final image/report is not uniquely bound to this routed DB'
}
foreach($taskRole in @('timing_log','bitstream_log')){
 if(@($taskFinal.outputs | Where-Object {$_.role -eq $taskRole}).Count -ne 1){throw "Missing unique native log: $taskRole"}
}
$taskSbit=$taskFinalSbit[0].path
$taskReport=$taskFinalReport[0].path
# Purpose: freeze converter and runtime as well as its explicit arguments;
# the official installation is never patched for XT25F128.
$taskRuntime=(Resolve-Path -LiteralPath $CfgRuntime).Path
$taskExe=Join-Path $taskRuntime 'bin/cdt_cfg_shell.exe'
$taskList=Join-Path $taskRuntime 'arch/vendor/pango/arch/cdt/flash_list_cd.cfl'
if(!(Select-String -LiteralPath $taskList -Pattern '"xt25f128"' -Quiet)){throw 'Selected runtime lacks XT25F128'}
$taskConvertTcl=Join-Path $PSScriptRoot 'convert_comms_sfc.tcl'
$taskRuntimeHashes=@($taskExe,$taskList,$taskConvertTcl,$PSCommandPath,
 (Join-Path $PSScriptRoot 'check_mcu_reply_evidence.ps1') | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
})
$taskSbitHash=(Get-FileHash -LiteralPath $taskSbit).Hash
$taskRelease=Join-Path $taskFpga ('release/geometry_'+(Get-Date -Format yyyyMMdd)+'_'+$taskSbitHash.Substring(0,12).ToLower())
if(Test-Path -LiteralPath $taskRelease){throw 'Release exists; never overwrite evidence'}
New-Item -ItemType Directory -Path $taskRelease | Out-Null
Copy-Item -LiteralPath $taskSbit -Destination (Join-Path $taskRelease 'mini_raw8_geometry.sbit')
Copy-Item -LiteralPath $taskReport -Destination (Join-Path $taskRelease 'stage_report.rtr')
Copy-Item -LiteralPath (Join-Path $taskRun 'source_manifest.json'),(Join-Path $taskRun 'result.json') -Destination $taskRelease
Copy-Item -LiteralPath $taskFinalEvidence -Destination (Join-Path $taskRelease 'generation_evidence.json')
# Purpose: preserve the reviewed resource corpus reference and executable gate
# as separate release evidence, without relabeling isolated LUTs as full-board.
$taskResourceCopies=@(
 [ordered]@{path=(Join-Path $taskRelease 'resource_evidence.json');sha256=$taskResourceCheck.hashes[0].sha256},
 [ordered]@{path=(Join-Path $taskRelease 'resource_manifest.json');sha256=$taskResourceCheck.hashes[1].sha256},
 [ordered]@{path=(Join-Path $taskRelease 'check_geometry_resource_evidence.ps1');sha256=$taskResourceCheck.hashes[2].sha256})
Copy-Item -LiteralPath $taskResourceCheck.evidence -Destination $taskResourceCopies[0].path
Copy-Item -LiteralPath $taskResourceCheck.manifest -Destination $taskResourceCopies[1].path
Copy-Item -LiteralPath $taskResourceChecker -Destination $taskResourceCopies[2].path
Assert-Hashes $taskResourceCopies
# Purpose: archive every verified timing-proof byte, including the original
# golden, current source, renamed fixture, runner/bench snapshots and 40 logs.
# Numbered flat names avoid path-length collisions; manifest records identity.
$taskTimingArchive=Join-Path $taskRelease 'cache_valid_parallel'
New-Item -ItemType Directory -Path $taskTimingArchive|Out-Null
$taskTimingCopies=@();$taskTimingIndex=0
foreach($record in $taskTimingCheck.hashes){
 $taskTimingName=('{0:D3}_' -f $taskTimingIndex)+[IO.Path]::GetFileName($record.path)
 $taskTimingDestination=Join-Path $taskTimingArchive $taskTimingName
 Copy-Item -LiteralPath $record.path -Destination $taskTimingDestination
 $taskTimingCopies+=[pscustomobject]@{source=$record.path;path=$taskTimingDestination;sha256=$record.sha256}
 $taskTimingIndex++
}
Assert-Hashes $taskTimingCopies
# Purpose: archive the exact checked boot proof without copying simulator work
# libraries/waves. Metadata still records original immutable source paths; each
# copied source/log is additionally bound byte-for-byte in the release manifest.
$taskBootArchive=Join-Path $taskRelease 'boot_epoch'
New-Item -ItemType Directory -Path $taskBootArchive | Out-Null
$taskBootPairs=@()
foreach($name in @('result.json','source_manifest.json','source_verification.json','compile.log','full.log','clock125.log','full_transcript.log','clock125_transcript.log')){
 $taskBootPairs+=[pscustomobject]@{source=(Join-Path $taskBoot $name);destination=(Join-Path $taskBootArchive $name)}
}
New-Item -ItemType Directory -Path (Join-Path $taskBootArchive 'sources') | Out-Null
foreach($file in (Get-ChildItem (Join-Path $taskBoot 'sources') -File)){
 $taskBootPairs+=[pscustomobject]@{source=$file.FullName;destination=(Join-Path $taskBootArchive ('sources/'+$file.Name))}
}
$taskBootPairs+=[pscustomobject]@{source=$taskBootChecker;destination=(Join-Path $taskBootArchive 'check_geometry_boot_epoch_evidence.ps1')}
$taskBootCopies=@(foreach($pair in $taskBootPairs){
 $bound=@($taskBootCheck.hashes | Where-Object {[IO.Path]::GetFullPath($_.path) -eq [IO.Path]::GetFullPath($pair.source)})
 if($bound.Count -ne 1){throw 'Unbound or duplicate boot proof copy'}
 Copy-Item -LiteralPath $pair.source -Destination $pair.destination
 [pscustomobject]@{path=$pair.destination;sha256=$bound[0].sha256}
})
Assert-Hashes $taskBootCopies
# Keep native-checkpoint provenance alongside the release when routing was
# resumed; these records were verified above, not synthesized from filenames.
foreach($taskEvidenceName in @('checkpoint_hashes.json','routed_db_hash.json','ddr_placement_audit.json','ddr_physical_verified.json')){
 if(Test-Path -LiteralPath (Join-Path $taskRun $taskEvidenceName)){
  Copy-Item -LiteralPath (Join-Path $taskRun $taskEvidenceName) -Destination $taskRelease
 }
}
$taskOldSbit=$env:COMMS_SBIT;$taskOldSfc=$env:COMMS_SFC
$taskPassed=$false
$taskConversionEvidence=$null
Push-Location $taskRelease
try {
 $env:COMMS_SBIT=Join-Path $taskRelease 'mini_raw8_geometry.sbit'
 $env:COMMS_SFC=Join-Path $taskRelease 'mini_raw8_geometry.sfc'
 $taskTcl=$taskConvertTcl.Replace('\','/')
 # Installed Fabric Configuration guide 4.5.6: conversion only, opcode 0x0B,
 # SPI x1, address zero. The reused Tcl has no scan/connect/erase commands.
 "source {$taskTcl}" | & $taskExe 2>&1 | Tee-Object conversion.log
 if($LASTEXITCODE -or !(Select-String conversion.log -Pattern 'COMMS_SFC_OFFLINE_GENERATED' -Quiet) -or
  (Select-String conversion.log -Pattern '^E:|Check license failed|is not supported' -Quiet)){
  throw 'Offline SFC conversion failed'
 }
 if((Get-Item -LiteralPath $env:COMMS_SFC).Length -lt 10000 -or
  (Get-Item -LiteralPath $env:COMMS_SFC).Length -gt 16MB){throw 'Converted image outside XT25F128 capacity/size bounds'}
 # Purpose: a minimum size alone cannot detect a truncated payload. Perform
 # a second native conversion from the same hash-bound SBIT into a separate
 # fresh file, requiring identical complete length and SHA256. Do not assume
 # that all SBIT and SFC formats are byte-identical; trust native conversion
 # semantics, not an undocumented header/payload parser.
 $taskFirstSfc=$env:COMMS_SFC
 $taskFirstHash=(Get-FileHash -LiteralPath $taskFirstSfc).Hash
 $taskCheckDir=Join-Path $taskRelease 'conversion_check'
 New-Item -ItemType Directory -Path $taskCheckDir | Out-Null
 $env:COMMS_SFC=Join-Path $taskCheckDir 'mini_raw8_geometry.sfc'
 "source {$taskTcl}" | & $taskExe 2>&1 | Tee-Object (Join-Path $taskCheckDir 'conversion.log')
 if($LASTEXITCODE -or
  !(Select-String (Join-Path $taskCheckDir 'conversion.log') -Pattern 'COMMS_SFC_OFFLINE_GENERATED' -Quiet) -or
  (Select-String (Join-Path $taskCheckDir 'conversion.log') -Pattern '^E:|Check license failed|is not supported' -Quiet)){
  throw 'Independent offline SFC conversion failed'
 }
 if((Get-Item -LiteralPath $env:COMMS_SFC).Length -ne (Get-Item -LiteralPath $taskFirstSfc).Length -or
  (Get-FileHash -LiteralPath $env:COMMS_SFC).Hash -ne $taskFirstHash -or
  (Get-FileHash -LiteralPath $taskFirstSfc).Hash -ne $taskFirstHash){throw 'SFC differs from independent native conversion'}
 $taskConversionEvidence=[ordered]@{passed=$true;method='Independent native repeat conversion, identical full length and SHA256';
  device='xt25f128';opcode=11;spi_width=1;start_address=0;
  sbit_sha256=$taskSbitHash;sbit_bytes=(Get-Item -LiteralPath $env:COMMS_SBIT).Length;
  sfc_sha256=$taskFirstHash;sfc_bytes=(Get-Item -LiteralPath $taskFirstSfc).Length;
  repeated_sfc=$env:COMMS_SFC;runtime_and_script_hashes=$taskRuntimeHashes;hardware_readback=$false}
 $taskConversionEvidence | ConvertTo-Json -Depth 6 | Set-Content conversion_evidence.json -Encoding utf8
 Assert-Hashes $taskRuntimeHashes
 Assert-Hashes $taskInputs
 Assert-Hashes $taskFinal.inputs
 Assert-Hashes $taskFinal.outputs
 # Purpose: recheck frozen reply evidence after conversion so packaging cannot
 # accept logs or the tested candidate being changed during native export.
 $null=& (Join-Path $PSScriptRoot 'check_mcu_reply_evidence.ps1') -EvidenceDirectory $taskReply
 # Purpose: recheck the board-only boot contract, original proof/checker and
 # archived bytes after both offline conversions; an old DEFAULT-mode proof
 # alone must never qualify this specialized physical top.
 Assert-Hashes $taskBootCheck.hashes
 $null=Assert-BootEpochEquivalence $taskBoot $taskBootChecker
 Assert-Hashes $taskBootCheck.hashes
 Assert-Hashes $taskBootCopies
 # Purpose: after both conversions recheck originals, saved semantic result,
 # checker SHA and release copies before permitting offline_package_ready.
 Assert-Hashes $taskResourceCheck.hashes
 $null=Assert-ResourceEquivalence $taskResource $taskResourceChecker $taskTiming
 Assert-Hashes $taskResourceCheck.hashes
 Assert-Hashes $taskResourceCopies
 # Recompute the mandatory proof after conversion and verify frozen originals
 # plus copied bytes. No optional timing proof or self-reported PASS path exists.
 Assert-Hashes $taskTimingCheck.hashes
 $null=Assert-CacheTimingEquivalence $taskTiming $taskTimingChecker
 Assert-Hashes $taskTimingCheck.hashes
 Assert-Hashes $taskTimingCopies
 if((Get-FileHash -LiteralPath $env:COMMS_SBIT).Hash -ne $taskSbitHash){throw 'SBIT changed'}
 $taskPassed=$true
} finally {
 # Incomplete packages are visibly NOT ready; never mark hardware verified
 # from offline success. Gray correction is not RGB S1/S2 or real 1080p30.
 [ordered]@{offline_package_ready=$taskPassed;target='PG2L100H-6FBG676';flash='XT25F128';
  spi_width=1;opcode=11;start_address=0;timing_constraints_met=$true;
  programmed=$false;flash_verified=$false;cold_boot_verified=$false;hardware_tested=$false;
  external_dvp_timing_verified=$false;realtime_1080p30_verified=$false;
  scope='Unmarked enhanced Bayer RAW8 Ethernet + pipelined FPGA gray correction/original HDMI with 20 markers; bring-up candidate';
  build=$taskRun;board_simulation=$taskBoard;chain_simulation=$taskChain;equivalence=$taskEq;mcu_simulation=$taskMcu;
  queue_simulation=$taskQueue;decoder_equivalence=$taskDecoder;
  cache_equivalence=$taskCache;snapshot_equivalence=$taskSnapshot;packet_simulation=$taskPacket;
  original_simulation=$taskOriginal;marker_simulation=$taskMarkers;window_simulation=$taskWindow;
  map_simulation=$taskMap;writer_simulation=$taskWriter;
  predecode_simulation=$taskPredecode;
  view_predecode_simulation=$taskViewPredecode;divider_simulation=$taskDivider;
  core_read_simulation=$taskCoreRead;
  reply_equivalence=$taskReplyCheck;
  boot_epoch_equivalence=[ordered]@{directory=$taskBoot;proof=$taskBootCheck.check;
   frozen_originals=$taskBootCheck.hashes;release_copies=$taskBootCopies};
  cache_timing_equivalence=[ordered]@{directory=$taskTiming;proof=$taskTimingCheck.check;
   frozen_originals=$taskTimingCheck.hashes;release_copies=$taskTimingCopies};
  resource_equivalence=[ordered]@{directory=$taskResource;schema_version='geometry-resource-evidence/v2';
   evidence='resource_evidence.json';manifest='resource_manifest.json';checker='check_geometry_resource_evidence.ps1';
   frozen_originals=$taskResourceCheck.hashes;release_copies=$taskResourceCopies};
  generation_evidence=$taskFinalEvidence;conversion_evidence=$taskConversionEvidence;
  runtime_hashes=$taskRuntimeHashes;
  files=@(Get-ChildItem -LiteralPath $taskRelease -File | Where-Object {$_.Extension -in @('.sbit','.sfc','.rtr')} | ForEach-Object {
   [ordered]@{name=$_.Name;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
  })} | ConvertTo-Json -Depth 6 | Set-Content manifest.json -Encoding utf8
 $env:COMMS_SBIT=$taskOldSbit;$env:COMMS_SFC=$taskOldSfc;Pop-Location
}
Write-Output "GEOMETRY_CANDIDATE_EXPORTED $taskRelease"
