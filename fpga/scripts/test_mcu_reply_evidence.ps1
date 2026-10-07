# Purpose: exercise publication fail-closed checks on disposable project-owned
# fixture copies. Never modify the frozen simulation evidence or formal RTL.
param([Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/reply_gate_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskFixture=Join-Path $taskRun 'fixture'
New-Item -ItemType Directory -Path $taskFixture -Force | Out-Null
$taskSource=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
$taskResult=Get-Content (Join-Path $taskSource 'result.json') -Raw | ConvertFrom-Json
foreach($taskRel in (@($taskResult.inputs.path)+@($taskResult.snapshots.path)+@($taskResult.results.path)+@('result.json') | Sort-Object -Unique)){
 $taskTo=Join-Path $taskFixture $taskRel
 New-Item -ItemType Directory -Path (Split-Path $taskTo -Parent) -Force | Out-Null
 Copy-Item -LiteralPath (Join-Path $taskSource $taskRel) -Destination $taskTo
}
$taskGate=Join-Path $PSScriptRoot 'check_mcu_reply_evidence.ps1'
$taskChecks=[Collections.Generic.List[object]]::new()
function Test-ReplyGate([string]$Name,[bool]$ShouldPass){
 $taskDidPass=$false;$taskError=$null
 try{ $null=& $taskGate -EvidenceDirectory $taskFixture; $taskDidPass=$true }
 catch{$taskError=$_.Exception.Message}
 if($taskDidPass -ne $ShouldPass){throw "Unexpected gate outcome: $Name : $taskError"}
 $taskChecks.Add([pscustomobject]@{case=$Name;passed=$true;accepted=$taskDidPass;error=$taskError})
}
Test-ReplyGate 'valid-current-production' $true
# Purpose: generate deliberately incomplete/malformed metadata in the fixture;
# restoration always comes from the immutable source result, not patched gold.
foreach($taskCase in @('false-pass','missing-log','duplicate-case','bad-hash','stale-production','path-traversal',
 'string-proof','string-golden','missing-testbench','missing-runner','missing-snapshot','duplicate-input')){
 $taskAltered=Get-Content (Join-Path $taskSource 'result.json') -Raw | ConvertFrom-Json
 switch($taskCase){
  'false-pass' {$taskAltered.passed=$false}
  'missing-log' {$taskAltered.results=@($taskAltered.results | Select-Object -Skip 1)}
  'duplicate-case' {$taskAltered.results[1].path=$taskAltered.results[0].path}
  'bad-hash' {$taskAltered.inputs[0].sha256='not-a-hash'}
  'stale-production' {$taskAltered.candidate_sha256=('0'*64)}
  'path-traversal' {$taskAltered.inputs[0].path='../outside.v'}
  'string-proof' {$taskAltered.cycle_equivalence_observed='false'}
  'string-golden' {$taskAltered.golden_only_module_renames='false'}
  'missing-testbench' {$taskAltered.inputs=@($taskAltered.inputs | Where-Object {$_.path -ne 'sim/tb_mcu_protocol.sv'})}
  'missing-runner' {$taskAltered.inputs=@($taskAltered.inputs | Where-Object {$_.path -ne 'run_tests.ps1'})}
  'missing-snapshot' {$taskAltered.snapshots=@($taskAltered.snapshots | Select-Object -Skip 1)}
  'duplicate-input' {$taskAltered.inputs[1]=$taskAltered.inputs[0]}
 }
 $taskAltered | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $taskFixture 'result.json') -Encoding utf8
 Test-ReplyGate $taskCase $false
}
Copy-Item -LiteralPath (Join-Path $taskSource 'result.json') -Destination (Join-Path $taskFixture 'result.json')
Test-ReplyGate 'restored-fixture' $true
# Purpose: copy genuine logs under wrong case names and update fixture hashes.
# Rejection must come from execution coverage, not merely changed file hashes.
foreach($taskMutation in @(
 @{name='wrong-decoder-configuration';from='results/decoder/g0_d0_f0.log';to='results/decoder/g1_d1_f7.log'},
 @{name='wrong-uart-clock';from='results/uart_verified/protocol_full.log';to='results/uart_verified/protocol_125mhz.log'},
 @{name='wrong-geometry-cycle-clock';from='results/geometry_verified/geometry_uart.log';to='results/geometry_verified/geometry_125mhz.log'},
 @{name='wrong-display-mode';from='results/geometry_verified/view_enabled.log';to='results/geometry_verified/view_disabled.log'})){
 $taskAltered=Get-Content (Join-Path $taskSource 'result.json') -Raw | ConvertFrom-Json
 $taskTo=Join-Path $taskFixture $taskMutation.to
 Copy-Item -LiteralPath (Join-Path $taskSource $taskMutation.from) -Destination $taskTo
 ($taskAltered.results | Where-Object {$_.path -eq $taskMutation.to}).sha256=(Get-FileHash -LiteralPath $taskTo).Hash
 $taskAltered | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $taskFixture 'result.json') -Encoding utf8
 Test-ReplyGate $taskMutation.name $false
 Copy-Item -LiteralPath (Join-Path $taskSource $taskMutation.to) -Destination $taskTo
}
Copy-Item -LiteralPath (Join-Path $taskSource 'result.json') -Destination (Join-Path $taskFixture 'result.json')
Test-ReplyGate 'final-restored-fixture' $true
[ordered]@{passed=$true;checks=@($taskChecks);fixture_only=$true;
 gate_sha256=(Get-FileHash -LiteralPath $taskGate).Hash;
 script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;
 evidence_sha256=(Get-FileHash -LiteralPath (Join-Path $taskSource 'result.json')).Hash} |
 ConvertTo-Json -Depth 6 | Set-Content (Join-Path $taskRun 'result.json') -Encoding utf8
"MCU_REPLY_GATE_TEST_PASS cases=$($taskChecks.Count) $taskRun"
