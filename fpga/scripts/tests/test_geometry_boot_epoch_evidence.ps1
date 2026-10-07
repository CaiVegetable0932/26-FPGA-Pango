# Purpose: PS5.1/7 semantic adversarial corpus for the read-only boot proof gate.
# Mutations affect ONLY a finite private relocated fixture; production proof is read-only.
[CmdletBinding()]
param([string]$OutputDirectory='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$checker=Join-Path $project 'fpga/scripts/check_geometry_boot_epoch_evidence.ps1'
$flavor=if($PSVersionTable.PSVersion.Major -eq 5){'ps51'}else{'ps7'}
$build=[IO.Path]::GetFullPath((Join-Path $project 'fpga/build')).TrimEnd('\','/')
# Fresh replay may select a project-owned build child; reject aliases/existing trees.
if(-not $OutputDirectory){$OutputDirectory=Join-Path $build ('boot_epoch_evidence_tests_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+$flavor+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))}
$out=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if(-not $out.StartsWith($build+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'OutputDirectory must be a private project build descendant'}
$ancestor=Split-Path $out -Parent
while($ancestor.Length -ge $project.Length){
 if((Test-Path -LiteralPath $ancestor) -and (((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'OutputDirectory reparse ancestor forbidden'}
 if($ancestor -ieq $project){break};$ancestor=Split-Path $ancestor -Parent
}
if(Test-Path -LiteralPath $out){throw 'Private test output already exists; preserve it, do not overwrite'}
$fixture=Join-Path $out 'fixture';New-Item -ItemType Directory -Path $fixture|Out-Null
$fixtureChecker=Join-Path $fixture 'fpga/scripts/check_geometry_boot_epoch_evidence.ps1'
$fixtureTest=Join-Path $fixture 'fpga/scripts/tests/test_geometry_boot_epoch_evidence.ps1'
$activeChecker=$checker
$checkerBefore=(Get-FileHash -LiteralPath $checker).Hash
$testBefore=(Get-FileHash -LiteralPath $PSCommandPath).Hash
$rel='fpga/build/mcu_stable_epoch_proof_20261007_144143_995'
# Replay only the new Top/runner proof; original evidence is never rebaselined.
$attempt='attempt_20261007_161933_853_98ae2b14'
$original=Join-Path (Join-Path $project $rel) $attempt
$dir=Join-Path (Join-Path $fixture $rel) $attempt
$records=New-Object 'System.Collections.Generic.List[object]'
$utf8=New-Object Text.UTF8Encoding($false)
function ReadJson([string]$Path){
 $text=[IO.File]::ReadAllText($Path)
 if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ($text|ConvertFrom-Json -DateKind String)}
 return ($text|ConvertFrom-Json)
}
function SaveJson([string]$Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 20),$utf8)}
function CopyPrivate([string]$Source,[string]$Destination){
 if(-not $Source.StartsWith($project+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $Destination.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture copy escapes finite roots'}
 New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force|Out-Null
 Copy-Item -LiteralPath $Source -Destination $Destination
}
function BindMetadata {
 $r=ReadJson (Join-Path $dir 'result.json')
 $r.source_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $dir 'source_manifest.json')).Hash
 foreach($run in $r.runs){$run.log_sha256=(Get-FileHash -LiteralPath (Join-Path $dir $run.log)).Hash}
 SaveJson (Join-Path $dir 'result.json') $r
}
function Good($Object){
 if($Object -isnot [pscustomobject] -or $Object.passed -isnot [bool] -or -not $Object.passed -or $Object.schema_version -cne 'geometry-boot-epoch-evidence/v1' -or $Object.inputs.Count -ne 30 -or $Object.actual_compile_inputs.Count -ne 8){throw 'Gate interface mismatch'}
 foreach($inputRecord in $Object.inputs){if((Get-FileHash -LiteralPath $inputRecord.path).Hash -cne $inputRecord.sha256){throw 'Returned artifact binding mismatch'}}
}
function Positive([string]$Name,[string]$Evidence,[string]$Root){
 $value=& $activeChecker -EvidenceDirectory $Evidence -WorkspaceRoot $Root;Good $value
 $records.Add([pscustomobject]@{name=$Name;expected_reject=$false;passed=$true;reason='approved';artifact_count=$value.inputs.Count})
}
# Store baseline fixture bytes in memory; every rejected mutation is also preserved
# alongside its exact exception, then the fixture is restored without touching live RTL.
$baseline=@{}
function Negative([string]$Name,[scriptblock]$Mutation){
 $case=Join-Path $out ('cases/'+$Name);New-Item -ItemType Directory -Path $case -Force|Out-Null
 $caught=$null;$value=$null
 try{
  & $Mutation
  $changes=0
  foreach($p in $baseline.Keys){
   $now=[IO.File]::ReadAllBytes($p)
   if([Convert]::ToBase64String($now) -cne [Convert]::ToBase64String($baseline[$p])){
    $changes++;$dest=Join-Path $case $p.Substring($fixture.Length+1)
    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force|Out-Null
    [IO.File]::WriteAllBytes($dest,$now)
   }
  }
  if($changes -eq 0){throw ('Harness mutation did not change bytes: '+$Name)}
  try{$value=& $activeChecker -EvidenceDirectory $dir -WorkspaceRoot $fixture}catch{$caught=$_.Exception.Message}
  $ok=($null -ne $caught)
  $reason=if($ok){$caught}else{'Unexpected acceptance'}
  [IO.File]::WriteAllText((Join-Path $case 'checker.log'),$reason,$utf8)
  $records.Add([pscustomobject]@{name=$Name;expected_reject=$true;passed=$ok;reason=$reason})
  if(-not $ok){throw ('Negative accepted: '+$Name)}
 }finally{foreach($p in $baseline.Keys){[IO.File]::WriteAllBytes($p,$baseline[$p])}}
}
function ChangeJson([string]$Name,[scriptblock]$Edit){$p=Join-Path $dir $Name;$o=ReadJson $p;& $Edit $o;SaveJson $p $o}
function ChangeLog([string]$Name,[scriptblock]$Edit){$p=Join-Path $dir $Name;$s=[IO.File]::ReadAllText($p);$s=& $Edit $s;[IO.File]::WriteAllText($p,$s,$utf8);BindMetadata}
$success=$false;$failure=$null
try{
 Positive 'production_top39_161933' $original $project
 # Both previously approved attempts must now fail closed as stale for current
 # Top/runner. Exercise their real directories without any old evidence writes.
 foreach($stale in @('attempt_20261007_145640_309_b567e5df','attempt_20261007_145422_288_46e194d7')){
  $caught=$null
  try{& $activeChecker -EvidenceDirectory (Join-Path (Join-Path $project $rel) $stale) -WorkspaceRoot $project|Out-Null}catch{$caught=$_.Exception.Message}
  if(-not $caught -or $caught -notmatch 'unapproved/stale EvidenceDirectory'){throw ('Historic attempt unexpectedly approved: '+$stale)}
  $records.Add([pscustomobject]@{name=('stale_'+$stale);expected_reject=$true;passed=$true;reason=$caught})
 }
 # Exact copied checker derives the fixture itself as its production project root.
 # No gate allowlist edits/test bypass are required for arbitrary fresh replay dirs.
 CopyPrivate $checker $fixtureChecker
 CopyPrivate $PSCommandPath $fixtureTest
 if((Get-FileHash -LiteralPath $fixtureChecker).Hash -cne $checkerBefore -or (Get-FileHash -LiteralPath $fixtureTest).Hash -cne $testBefore){throw 'Harness/checker snapshot race'}
 $activeChecker=$fixtureChecker
 $manifest=ReadJson (Join-Path $original 'source_manifest.json')
 foreach($item in $manifest.files){foreach($p in @($item.path,$item.frozen)){CopyPrivate $p (Join-Path $fixture $p.Substring($project.Length+1))}}
 foreach($name in @('source_manifest.json','source_verification.json','result.json','compile.log','full.log','clock125.log','full_transcript.log','clock125_transcript.log')){
  $dest=Join-Path $dir $name;CopyPrivate (Join-Path $original $name) $dest
  # This is a mechanical relocation of private evidence, not rebaselining real proof.
  $s=[IO.File]::ReadAllText($dest).Replace($project.Replace('\','\\'),$fixture.Replace('\','\\')).Replace($project,$fixture).Replace($project.Replace('\','/'),$fixture.Replace('\','/'))
  [IO.File]::WriteAllText($dest,$s,$utf8)
 }
 BindMetadata
 foreach($f in Get-ChildItem -LiteralPath $fixture -File -Recurse){$baseline[$f.FullName]=[IO.File]::ReadAllBytes($f.FullName)}
 Positive 'relocated_private_fixture' $dir $fixture
 $a=& $activeChecker -EvidenceDirectory $dir -WorkspaceRoot $fixture
 $b=& $activeChecker -EvidenceDirectory $dir -WorkspaceRoot $fixture
 if(($a|ConvertTo-Json -Depth 20 -Compress) -cne ($b|ConvertTo-Json -Depth 20 -Compress)){throw 'Unstable output'}
 foreach($p in $baseline.Keys){if([Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) -cne [Convert]::ToBase64String($baseline[$p])){throw 'Checker wrote evidence'}}
 $records.Add([pscustomobject]@{name='deterministic_and_readonly';expected_reject=$false;passed=$true;reason='all bytes unchanged'})
 Negative 'empty_manifest' {ChangeJson 'source_manifest.json' {$args[0].files=@()};BindMetadata}
 Negative 'missing_role' {ChangeJson 'source_manifest.json' {$args[0].files=@($args[0].files[0..9])};BindMetadata}
 Negative 'extra_role' {ChangeJson 'source_manifest.json' {$args[0].files+=@($args[0].files[0])};BindMetadata}
 Negative 'duplicate_role' {ChangeJson 'source_manifest.json' {$args[0].files[3]=$args[0].files[2]};BindMetadata}
 Negative 'unknown_manifest_key' {ChangeJson 'source_manifest.json' {$args[0]|Add-Member ignored $true};BindMetadata}
 Negative 'wrong_schema' {ChangeJson 'source_manifest.json' {$args[0].schema='other'};BindMetadata}
 Negative 'manifest_stringtrue' {ChangeJson 'source_manifest.json' {$args[0].captured_before_compile='true'};BindMetadata}
 Negative 'result_stringtrue' {ChangeJson 'result.json' {$args[0].passed='true'}}
 Negative 'result_stringfalse' {ChangeJson 'result.json' {$args[0].hardware_tested='false'}}
 Negative 'sourcechanged_false' {ChangeJson 'result.json' {$args[0].sources_unchanged=$false}}
 Negative 'unknown_result_key' {ChangeJson 'result.json' {$args[0]|Add-Member ignored $false}}
 Negative 'missing_result_key' {ChangeJson 'result.json' {$args[0].PSObject.Properties.Remove('sources_unchanged')}}
 Negative 'single_config' {ChangeJson 'result.json' {$args[0].runs=@($args[0].runs[0])}}
 Negative 'duplicate_config' {ChangeJson 'result.json' {$args[0].runs[1]=$args[0].runs[0]}}
 Negative 'wrong_clock' {ChangeJson 'result.json' {$args[0].runs[1].clock_hz=125000001}}
 Negative 'wrong_baud' {ChangeJson 'result.json' {$args[0].runs[0].baud=9600}}
 Negative 'run_stringfalse' {ChangeJson 'result.json' {$args[0].runs[1].full='false'}}
 Negative 'acc_disabled' {ChangeJson 'result.json' {$args[0].runs[0].plus_acc=$false}}
 Negative 'native_exit_failed' {ChangeJson 'result.json' {$args[0].runs[0].exit_code=1}}
 Negative 'unknown_run_key' {ChangeJson 'result.json' {$args[0].runs[0]|Add-Member ignored 0}}
 Negative 'log_path_abuse' {ChangeJson 'result.json' {$args[0].runs[0].log='../full.log'}}
 Negative 'manifest_hash_drift' {ChangeJson 'result.json' {$args[0].source_manifest_sha256=('0'*64)}}
 Negative 'actual_log_hash_drift' {ChangeJson 'result.json' {$args[0].runs[0].log_sha256=('0'*64)}}
 Negative 'source_path_abuse' {ChangeJson 'source_manifest.json' {$args[0].files[2].path=(Join-Path $project 'fpga/rtl/control/mcu_protocol.v')};BindMetadata}
 Negative 'snapshot_alias_live' {ChangeJson 'source_manifest.json' {$args[0].files[2].frozen=$args[0].files[2].path};BindMetadata}
 Negative 'candidate_vs_self' {ChangeJson 'source_manifest.json' {$args[0].files[0]=$args[0].files[2]};BindMetadata}
 Negative 'hash_rebaseline' {ChangeJson 'source_manifest.json' {$args[0].files[2].sha256=('0'*64)};BindMetadata}
 Negative 'wrong_source_bytes' {ChangeJson 'source_manifest.json' {$args[0].files[2].bytes=1};BindMetadata}
 Negative 'string_source_bytes' {ChangeJson 'source_manifest.json' {$args[0].files[2].bytes='26117'};BindMetadata}
 Negative 'verification_empty' {[IO.File]::WriteAllText((Join-Path $dir 'source_verification.json'),'[]',$utf8)}
 Negative 'verification_extra' {ChangeJson 'source_verification.json' {$args[0][0]|Add-Member ignored $true}}
 Negative 'verification_hash' {ChangeJson 'source_verification.json' {$args[0][2].snapshot=('0'*64)}}
 Negative 'live_source_drift' {$p=Join-Path $fixture 'fpga/rtl/control/mcu_protocol.v';[IO.File]::AppendAllText($p,'// drift',$utf8)}
 Negative 'snapshot_source_drift' {$p=Join-Path $dir 'sources/tb_mcu_stable_link_epoch.sv';[IO.File]::AppendAllText($p,'// drift',$utf8)}
 Negative 'empty_compile' {ChangeLog 'compile.log' {''}}
 Negative 'ignored_compile' {ChangeLog 'compile.log' {$args[0].Replace('-- Compiling module mcu_protocol_golden','-- Ignoring module mcu_protocol_golden')}}
 Negative 'wrong_compile_path' {ChangeLog 'compile.log' {$args[0].Replace('sources\mcu_protocol.v','sources\mcu_protocol.old.v')}}
 Negative 'truncated_log_rehashed' {ChangeLog 'full.log' {$args[0].Substring(0,200)}}
 Negative 'stale_stats_rehashed' {ChangeLog 'full.log' {$args[0].Replace('single_bits=64','single_bits=63')}}
 Negative 'duplicate_pass_rehashed' {ChangeLog 'full.log' {$args[0]+"`n# MCU_STABLE_EPOCH_PASS duplicate"}}
 Negative 'wrong_native_params' {ChangeLog 'clock125.log' {$args[0].Replace('-gFULL=0','-gFULL=1')}}
 Negative 'transcript_mismatch' {ChangeLog 'full_transcript.log' {$args[0].Replace('max_queue=8','max_queue=1')}}
 Negative 'duplicate_json_key' {$p=Join-Path $dir 'result.json';$s=[IO.File]::ReadAllText($p);[IO.File]::WriteAllText($p,([regex]::Replace($s,'"passed"\s*:\s*true','"passed": true, "passed": true')),$utf8)}
 Negative 'nonfinite_json' {$p=Join-Path $dir 'result.json';$s=[IO.File]::ReadAllText($p);[IO.File]::WriteAllText($p,$s.Replace('1843200','1e309'),$utf8)}
 Negative 'truncated_json' {$p=Join-Path $dir 'result.json';[IO.File]::WriteAllText($p,'{"passed":true',$utf8)}
 Negative 'trailing_json' {$p=Join-Path $dir 'result.json';[IO.File]::AppendAllText($p,' true',$utf8)}
 Positive 'fixture_restored_final' $dir $fixture
 $success=$true
}catch{$failure=$_.Exception.ToString();throw}finally{
 # Preserve both completed negative cases and unexpected harness failures.
 # Freeze exact harness/gate bytes and bind before/after live plus copied identities.
 $freeze=@(foreach($pair in @(@($checker,$fixtureChecker,$checkerBefore),@($PSCommandPath,$fixtureTest,$testBefore))){
  $snapshotHash=if(Test-Path -LiteralPath $pair[1]){(Get-FileHash -LiteralPath $pair[1]).Hash}else{''}
  [pscustomobject]@{path=$pair[0];frozen=$pair[1];before=$pair[2];after=(Get-FileHash -LiteralPath $pair[0]).Hash;snapshot=$snapshotHash}
 })
 $unchanged=@($freeze|Where-Object {$_.before -cne $_.after -or $_.before -cne $_.snapshot}).Count -eq 0
 if($success -and -not $unchanged){$success=$false;$failure='Harness/checker source drift during replay'}
 $record=[ordered]@{schema_version='boot-epoch-evidence-tests/v1';passed=$success;powershell=$PSVersionTable.PSVersion.ToString();checker_sha256=$checkerBefore;test_sha256=$testBefore;sources_unchanged=$unchanged;source_verification=$freeze;cases=@($records.ToArray());failure=$failure}
 SaveJson (Join-Path $out 'result.json') $record
 [IO.File]::WriteAllText((Join-Path $out 'test.log'),($records|Format-Table name,passed,reason -AutoSize|Out-String -Width 220),$utf8)
 Write-Output ([pscustomobject]@{passed=$success;directory=$out;cases=$records.Count;negatives=@($records|Where-Object expected_reject).Count})
 if(-not $success -and $failure -eq 'Harness/checker source drift during replay'){throw $failure}
}
