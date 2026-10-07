# Purpose: bind the reviewed parallel-reply candidate's cycle comparisons to
# the production protocol bytes. This complements, not replaces, current-source
# board/UART regressions and routed STA; the isolated snapshot stays immutable.
param([Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskBuild=[IO.Path]::GetFullPath((Join-Path $taskFpga 'build'))
$taskEvidence=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
if(!$taskEvidence.StartsWith($taskBuild+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
 throw 'Reply evidence must belong to this FPGA build directory'
}
$taskResultPath=Join-Path $taskEvidence 'result.json'
$taskResult=Get-Content -LiteralPath $taskResultPath -Raw | ConvertFrom-Json
foreach($taskFlag in @('passed','cycle_equivalence_observed','golden_only_module_renames')){
 if($taskResult.$taskFlag -isnot [bool] -or !$taskResult.$taskFlag){throw "Reply proof flag must be boolean true: $taskFlag"}
}
if($taskResult.test_cases -ne 39 -or $taskResult.decoder_vectors -ne 4194304){
 throw 'Missing complete reviewed reply-equivalence matrix'
}
$taskRows=@($taskResult.inputs)+@($taskResult.snapshots)+@($taskResult.results)
if(!$taskResult.inputs.Count -or !$taskResult.snapshots.Count -or $taskResult.results.Count -ne 39){throw 'Empty reply evidence'}
# Purpose: enforce the reviewed compilation/dependency set, not merely hashes
# of whichever entries a result happens to list. Omissions and duplicates fail.
$taskRequiredInputs=@(
 'rtl/control/mcu_frame_rx.v','rtl/control/mcu_frame_tx.v','rtl/control/mcu_protocol.v',
 'rtl/control/mcu_uart_rx.v','rtl/control/mcu_uart_tx.v',
 'rtl/geometry/geometry_config_bank.v','rtl/geometry/geometry_lens_lut.v',
 'rtl/geometry/geometry_mul_pipe.v','rtl/geometry/geometry_view_control.v',
 'sim/mcu_protocol_golden.v','sim/parameters.hex','sim/tb_geometry_uart.sv',
 'sim/tb_geometry_view_uart.sv','sim/tb_mcu_decoder_equivalence.sv',
 'sim/tb_mcu_protocol.sv','sim/tb_mcu_snapshot_timing.sv','run_tests.ps1','verify_evidence.ps1')
$taskRequiredSnapshots=@('reference/AGENTS.md')
$taskRequiredSnapshots+=@($taskRequiredInputs | Where-Object {$_ -match '^rtl/|^sim/tb_'} | ForEach-Object {'reference/fpga/'+$_})
$taskRequiredSnapshots+=@('reference/fpga/scripts/sim_mcu_decoder_equivalence.ps1','reference/fpga/scripts/sim_mcu_protocol.ps1')
foreach($taskSet in @(@{entries=$taskResult.inputs;names=$taskRequiredInputs},@{entries=$taskResult.snapshots;names=$taskRequiredSnapshots})){
 if($taskSet.entries.Count -ne $taskSet.names.Count){throw 'Incomplete or expanded reply input set'}
 foreach($taskName in $taskSet.names){
  if(@($taskSet.entries | Where-Object {$_.path -ceq $taskName}).Count -ne 1){throw "Missing/duplicate reply input: $taskName"}
 }
}
foreach($taskEntry in $taskRows){
 # Purpose: reject traversal or stale local records before consulting banners;
 # the test record cannot redirect validation outside its frozen evidence root.
 if(!$taskEntry.path -or $taskEntry.sha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Malformed reply hash'}
 $taskPath=[IO.Path]::GetFullPath((Join-Path $taskEvidence $taskEntry.path))
 if(!$taskPath.StartsWith($taskEvidence+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
  throw 'Reply evidence path escapes snapshot'
 }
 if((Get-FileHash -LiteralPath $taskPath).Hash -ne $taskEntry.sha256){throw "Stale reply evidence: $taskPath"}
}
# Purpose: inspect the exact expected 32 decoder cases and seven sequential
# tests, not an arbitrary count of logs or a caller-supplied success flag.
$taskExpected=@{}
foreach($g in 0..1){foreach($d in 0..1){foreach($f in 0..7){
 $taskExpected["results/decoder/g${g}_d${d}_f${f}.log"]="MCU_DECODER_EQUIVALENCE_PASS geom=$g features=$f display=$d checks=131072"
}}}
$taskExpected['results/decoder/capture.log']='SNAPSHOT_TIMING_PASS cycles=100000 accepted=48171'
$taskExpected['results/uart_verified/protocol_full.log']='MCU_PROTOCOL_PASS clk=1843200 baud=115200 timeout_ms=2 full=1 checks=6538 events=3 responses=68'
$taskExpected['results/uart_verified/protocol_125mhz.log']='MCU_PROTOCOL_PASS clk=125000000 baud=115200 timeout_ms=20 full=0 checks=3201 events=3 responses=33'
$taskExpected['results/geometry_verified/geometry_uart.log']='GEOMETRY_UART_PASS checks=6073 responses=63'
$taskExpected['results/geometry_verified/geometry_125mhz.log']='GEOMETRY_UART_PASS checks=6073 responses=63'
$taskExpected['results/geometry_verified/view_enabled.log']='GEOMETRY_VIEW_UART_PASS display=1 responses=11'
$taskExpected['results/geometry_verified/view_disabled.log']='GEOMETRY_VIEW_UART_PASS display=0 responses=3'
# Deterministic frozen benches additionally report cycle comparison totals;
# these distinguish the two geometry clocks, whose legacy PASS lacks CLK_HZ.
$taskCycles=@{'results/uart_verified/protocol_full.log'=869232;
 'results/uart_verified/protocol_125mhz.log'=26588977;
 'results/geometry_verified/geometry_uart.log'=901937;
 'results/geometry_verified/geometry_125mhz.log'=50164935;
 'results/geometry_verified/view_enabled.log'=127728;
 'results/geometry_verified/view_disabled.log'=30824}
foreach($taskName in $taskExpected.Keys){
 if(@($taskResult.results | Where-Object {$_.path -ceq $taskName}).Count -ne 1){throw "Missing/duplicate reply case: $taskName"}
 $taskLog=Get-Content -LiteralPath (Join-Path $taskEvidence $taskName) -Raw
 $taskBanner='(?m)^#[ \t]+'+[regex]::Escape($taskExpected[$taskName])+'[ \t]*\r?$'
 if([regex]::Matches($taskLog,$taskBanner).Count -ne 1 -or $taskLog -match '\*\* (Fatal|Error)|_FAIL\b|_TIMEOUT\b|Failed to open readmem'){
  throw "Reply case failed: $taskName"
 }
 if($taskCycles.ContainsKey($taskName)){
  $taskCycleBanner='(?m)^#[ \t]+MCU_REPLY_CYCLE_PASS cycles='+$taskCycles[$taskName]+'[ \t]*\r?$'
  if([regex]::Matches($taskLog,$taskCycleBanner).Count -ne 1){throw "Wrong/missing cycle comparison: $taskName"}
 }
}
# Purpose: golden logic may differ only by module renaming, and the candidate
# actually exercised must match the production bytes being packaged now.
$taskBaseline=Join-Path $taskEvidence 'reference/fpga/rtl/control/mcu_protocol.v'
$taskGolden=[IO.File]::ReadAllText($taskBaseline)
$taskGolden=[regex]::Replace($taskGolden,'\bmodule mcu_protocol\b','module mcu_protocol_golden')
$taskGolden=[regex]::Replace($taskGolden,'\bmcu_reply_queue_ram\b','mcu_reply_queue_ram_golden')
if($taskGolden -cne [IO.File]::ReadAllText((Join-Path $taskEvidence 'sim/mcu_protocol_golden.v'))){throw 'Golden logic changed'}
$taskCandidate=Join-Path $taskEvidence 'rtl/control/mcu_protocol.v'
$taskProduction=Join-Path $taskFpga 'rtl/control/mcu_protocol.v'
if((Get-FileHash -LiteralPath $taskBaseline).Hash -ne $taskResult.baseline_sha256 -or
 (Get-FileHash -LiteralPath $taskCandidate).Hash -ne $taskResult.candidate_sha256 -or
 (Get-FileHash -LiteralPath $taskProduction).Hash -ne $taskResult.candidate_sha256){throw 'Reply candidate differs from production'}
[pscustomobject]@{passed=$true;cases=39;production_sha256=$taskResult.candidate_sha256;
 evidence=$taskResultPath;evidence_sha256=(Get-FileHash -LiteralPath $taskResultPath).Hash;
 hardware_tested=$false;timing_verified=$false}
