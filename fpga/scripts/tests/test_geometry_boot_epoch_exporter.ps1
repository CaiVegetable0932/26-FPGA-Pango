# Purpose: execute ONLY AST-extracted boot-epoch exporter gates under PS5.1/7.
# The real exporter/checker/proof remain read-only; all adversarial writes are
# confined to a fresh private build fixture. No finalizer, converter or EDA runs.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,
 [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
$out=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if(-not $out.StartsWith((Join-Path $root 'fpga/build')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Private output must be under fpga/build'}
if(Test-Path -LiteralPath $out){throw 'Preserve existing output; choose a new directory'}
New-Item -ItemType Directory -Path $out|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$exporter=Join-Path $root 'fpga/scripts/export_geometry_candidate.ps1'
$realChecker=Join-Path $root 'fpga/scripts/check_geometry_boot_epoch_evidence.ps1'
$frozenExporter=(Get-FileHash -LiteralPath $exporter).Hash
$frozenChecker=(Get-FileHash -LiteralPath $realChecker).Hash
$records=New-Object 'System.Collections.Generic.List[object]'
$blocks=New-Object 'System.Collections.Generic.List[object]'
$success=$false;$failure=$null;$originalHashes=@();$errors=$null;$fixture=$null
function SaveJson([string]$Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 30),$utf8)}
function ReadJson([string]$Path){
 $s=[IO.File]::ReadAllText($Path)
 if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ($s|ConvertFrom-Json -DateKind String)}
 return ($s|ConvertFrom-Json)
}
function Check([string]$Name,[scriptblock]$Action,[bool]$Reject=$false,[string]$Reason=''){
 $caught=$null
 try{& $Action|Out-Null}catch{$caught=$_.Exception.Message}
 $ok=($null -ne $caught) -eq $Reject
 if($Reject -and $Reason){$ok=$ok -and $caught -match $Reason}
 $records.Add([pscustomobject]@{name=$Name;passed=[bool]$ok;expected_rejection=$Reject;reason=$caught})
 if(-not $ok){throw "Unexpected case $Name : $caught"}
 Write-Host "PASS $Name"
}
function Require($Condition,[string]$Message){if(-not $Condition){throw $Message}}
# Relocate a finite proof corpus, retaining byte-exact original logs separately.
# Only workspace-prefix text changes in runnable copies; normalized log bytes
# must equal the original before rebinding legitimate path/hash metadata.
function CopyPrivate([string]$Source,[string]$Destination){
 Require ($Source.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) 'Source outside reviewed workspace'
 Require ($Destination.StartsWith($out+'\',[StringComparison]::OrdinalIgnoreCase)) 'Destination outside private build'
 New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force|Out-Null
 Copy-Item -LiteralPath $Source -Destination $Destination
}
function NormalizeLog([string]$Text,[string]$Base){return $Text.Replace($Base,'<WORKSPACE>').Replace($Base.Replace('\','/'),'<WORKSPACE>').Replace("`r`n","`n")}
function BindMetadata {
 $p=Join-Path $taskBoot 'result.json';$r=ReadJson $p
 $r.source_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $taskBoot 'source_manifest.json')).Hash
 foreach($run in $r.runs){$run.log_sha256=(Get-FileHash -LiteralPath (Join-Path $taskBoot $run.log)).Hash}
 SaveJson $p $r
}
# Every negative mutation restores the same valid fixture bytes, even on error.
function EditPrivate([string]$Path,[scriptblock]$Mutation,[scriptblock]$Gate){
 Require ($Path.StartsWith($out+'\',[StringComparison]::OrdinalIgnoreCase)) 'Mutation outside private output'
 $bytes=[IO.File]::ReadAllBytes($Path)
 $resultPath=Join-Path $taskBoot 'result.json';$resultBytes=[IO.File]::ReadAllBytes($resultPath)
 try{& $Mutation $Path;& $Gate}finally{[IO.File]::WriteAllBytes($Path,$bytes);[IO.File]::WriteAllBytes($resultPath,$resultBytes)}
}
# Save exact AST extents for review. Executable blocks are selected by AST
# statements, never by running the exporter script or substituting its helpers.
function SaveBlock([string]$Name,$Nodes){
 $text=(@($Nodes)|ForEach-Object {$_.Extent.Text}) -join "`r`n"
 [IO.File]::WriteAllText((Join-Path $out ($Name+'.ps1')),$text,$utf8)
 $blocks.Add([pscustomobject]@{name=$Name;source_lines=@(@($Nodes)|ForEach-Object {$_.Extent.StartLineNumber});sha256=(Get-FileHash (Join-Path $out ($Name+'.ps1'))).Hash})
 return [scriptblock]::Create($text)
}
try{
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($exporter,[ref]$tokens,[ref]$errors)
 Require (@($errors).Count -eq 0) 'Exporter parser errors'
 foreach($name in @('Assert-Hashes','Assert-BootEpochEquivalence')){
  $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
  Require ($nodes.Count -eq 1) ('Unique actual helper required: '+$name)
  $null=SaveBlock $name $nodes
  Invoke-Expression $nodes[0].Extent.Text
 }
 $param=@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'BootEpochEquivalence'})
 Check 'parser_and_mandatory_argument' {Require ($param.Count -eq 1 -and $param[0].Extent.Text -match 'Mandatory\s*=\s*\$true') 'Boot gate argument must be mandatory'}
 $top=@($ast.EndBlock.Statements)
 $start=@($top|Where-Object {$_.Extent.Text -cmatch '^\$taskBootArchive='})
 $end=@($top|Where-Object {$_.Extent.Text -ceq 'Assert-Hashes $taskBootCopies'})
 Require ($start.Count -eq 1 -and $end.Count -eq 1) 'Unique actual boot copy block required'
 $copyNodes=@($top|Where-Object {$_.Extent.StartOffset -ge $start[0].Extent.StartOffset -and $_.Extent.EndOffset -le $end[0].Extent.EndOffset})
 $copy=SaveBlock 'release_copy_block' $copyNodes
 $postStart=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.PipelineAst] -and $n.Extent.Text -ceq 'Assert-Hashes $taskBootCheck.hashes'},$true)|Sort-Object {$_.Extent.StartOffset})
 Require ($postStart.Count -eq 2) 'Exactly two frozen-original postchecks required'
 $postParent=$postStart[0].Parent
 Require ($postParent -is [Management.Automation.Language.StatementBlockAst]) 'Postcheck must belong to try statement block'
 $postAll=@($postParent.Statements)
 $postEnd=@($postAll|Where-Object {$_.Extent.Text -ceq 'Assert-Hashes $taskBootCopies'})
 Require ($postEnd.Count -eq 1) 'Unique final copied-byte postcheck required'
 $postNodes=@($postAll|Where-Object {$_.Extent.StartOffset -ge $postStart[0].Extent.StartOffset -and $_.Extent.EndOffset -le $postEnd[0].Extent.EndOffset})
 Require ($postNodes.Count -eq 4) 'Bounded four-statement postcheck required'
 $post=SaveBlock 'post_conversion_block' $postNodes
 $manifestValues=@(foreach($table in $ast.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true)){
  foreach($pair in $table.KeyValuePairs){if($pair.Item1.Extent.Text -ceq 'boot_epoch_equivalence'){$pair.Item2}}
 })
 Require ($manifestValues.Count -eq 1) 'Unique actual release manifest field required'
 $manifestBlock=SaveBlock 'manifest_boot_field' $manifestValues
 Check 'preflight_before_finalizer_post_before_resource' {
  $pre=@($top|Where-Object {$_.Extent.Text -cmatch '^\$taskBootCheck=Assert-BootEpochEquivalence'})
  $final=@($top|Where-Object {$_.Extent.Text -cmatch '^\$taskFinalized=&'})
  $conversion=@($postAll|Where-Object {$_.Extent.Text -match '^\$taskConversionEvidence \| ConvertTo-Json'})
  $resource=@($postAll|Where-Object {$_.Extent.Text -ceq 'Assert-Hashes $taskResourceCheck.hashes'})
  Require ($pre.Count -eq 1 -and $final.Count -eq 1 -and $pre[0].Extent.EndOffset -lt $final[0].Extent.StartOffset) 'Boot preflight must precede finalizer'
  Require ($conversion.Count -eq 1 -and $resource.Count -eq 2 -and $conversion[0].Extent.EndOffset -lt $postStart[0].Extent.StartOffset -and $postEnd[0].Extent.EndOffset -lt $resource[0].Extent.StartOffset) 'Boot postcheck ordering changed'
 }
 # Validate production evidence read-only, then use a byte-identical copied
 # checker whose own project root is the finite isolated fixture workspace.
 # Bind the newly reviewed Top/runner attempt while extracting the actual,
 # unchanged exporter AST helpers/copy/postcheck blocks for this replay.
 $relative='fpga/build/mcu_stable_epoch_proof_20261007_144143_995/attempt_20261007_161933_853_98ae2b14'
 $original=Join-Path $root $relative;$taskFpga=Join-Path $root 'fpga'
 Check 'actual_top39_161933_helper' {$script:realContext=Assert-BootEpochEquivalence $original $realChecker;Require ($realContext.hashes.Count -eq 31) 'Expected 30 proof records plus checker'}
 $originalHashes=@($realContext.hashes)+@([pscustomobject]@{path=$exporter;sha256=$frozenExporter},[pscustomobject]@{path=(Join-Path $root 'fpga/scripts/tests/test_geometry_resource_exporter.ps1');sha256=(Get-FileHash (Join-Path $root 'fpga/scripts/tests/test_geometry_resource_exporter.ps1')).Hash})
 $fixture=Join-Path $out 'fixture';$taskBoot=Join-Path $fixture $relative
 $m=ReadJson (Join-Path $original 'source_manifest.json')
 foreach($row in $m.files){foreach($p in @($row.path,$row.frozen)){CopyPrivate $p (Join-Path $fixture $p.Substring($root.Length+1))}}
 foreach($name in @('result.json','source_manifest.json','source_verification.json','compile.log','full.log','clock125.log','full_transcript.log','clock125_transcript.log')){
  $src=Join-Path $original $name;$dest=Join-Path $taskBoot $name;CopyPrivate $src $dest
  $s=[IO.File]::ReadAllText($src)
  $rebased=$s.Replace($root.Replace('\','\\'),$fixture.Replace('\','\\')).Replace($root,$fixture).Replace($root.Replace('\','/'),$fixture.Replace('\','/'))
  if($name -like '*.log'){
   CopyPrivate $src (Join-Path $out ('original_logs/'+$name))
   Require ((NormalizeLog $s $root) -ceq (NormalizeLog $rebased $fixture)) 'Log corpus changed beyond workspace relocation'
  }
  [IO.File]::WriteAllText($dest,$rebased,$utf8)
 }
 $taskBootChecker=Join-Path $fixture 'fpga/scripts/check_geometry_boot_epoch_evidence.ps1';CopyPrivate $realChecker $taskBootChecker
 Require ((Get-FileHash $taskBootChecker).Hash -ceq $frozenChecker) 'Copied checker must be byte-identical'
 $taskFpga=Join-Path $fixture 'fpga';BindMetadata
 Check 'relocated_fixture_actual_helper' {$script:taskBootCheck=Assert-BootEpochEquivalence $taskBoot $taskBootChecker;Require ($taskBootCheck.check.passed -is [bool] -and $taskBootCheck.check.passed -and $taskBootCheck.hashes.Count -eq 31) 'Strict interface/count'}
 $taskRelease=Join-Path $out 'release_positive';New-Item -ItemType Directory -Path $taskRelease|Out-Null
 . $copy
 Check 'actual_release_copy_binding' {
  Require ($taskBootCopies.Count -eq 20) 'Expected metadata3 complete logs5 source11 checker1 copies'
  foreach($name in @('full_transcript.log','clock125_transcript.log')){Require (Test-Path -LiteralPath (Join-Path $taskRelease ('boot_epoch/'+$name)) -PathType Leaf) 'Complete transcript archive required'}
  Assert-Hashes $taskBootCopies
  foreach($pair in $taskBootPairs){Require ((Get-FileHash $pair.source).Hash -ceq (Get-FileHash $pair.destination).Hash) 'Release byte binding mismatch'}
 }
 Check 'post_conversion_actual_four_statements' {& $post}
 Check 'actual_manifest_field_binding' {
  $value=& $manifestBlock
  Require (($value.Keys|Sort-Object)-join '|' -ceq 'directory|frozen_originals|proof|release_copies') 'Manifest closed boot field'
  Require ($value.directory -ceq $taskBoot -and $value.proof.passed -is [bool] -and $value.proof.passed -and $value.frozen_originals.Count -eq 31 -and $value.release_copies.Count -eq 20) 'Manifest proof/hash binding'
  Assert-Hashes $value.frozen_originals;Assert-Hashes $value.release_copies
  SaveJson (Join-Path $out 'manifest_boot_field_result.json') $value
 }
 $gate={Assert-BootEpochEquivalence $taskBoot $taskBootChecker}
 Check 'missing_manifest_rejected' {
  $p=Join-Path $taskBoot 'source_manifest.json';[IO.File]::Move($p,$p+'.held')
  try{& $gate}finally{[IO.File]::Move($p+'.held',$p)}
 } $true 'missing file'
 Check 'result_passed_stringfalse_rejected' {EditPrivate (Join-Path $taskBoot 'result.json') {param($p) $r=ReadJson $p;$r.passed='false';SaveJson $p $r} $gate} $true 'passed typed bool'
 Check 'zero_byte_evidence_rejected' {EditPrivate (Join-Path $taskBoot 'source_verification.json') {param($p) [IO.File]::WriteAllText($p,'',$utf8)} $gate} $true 'empty evidence file'
 Check 'source_current_formal_drift_rejected' {EditPrivate (Join-Path $fixture 'fpga/rtl/control/mcu_protocol.v') {param($p) [IO.File]::AppendAllText($p,'// private current drift',$utf8)} $gate} $true 'actual source drift candidate'
 Check 'frozen_source_drift_rejected' {EditPrivate (Join-Path $taskBoot 'sources/mcu_protocol.v') {param($p) [IO.File]::AppendAllText($p,'// private frozen drift',$utf8)} $gate} $true 'actual source drift candidate'
 Check 'empty_manifest_rejected' {EditPrivate (Join-Path $taskBoot 'source_manifest.json') {param($p) $r=ReadJson $p;$r.files=@();SaveJson $p $r;BindMetadata} $gate} $true '11 closed source roles'
 Check 'duplicate_evidence_role_rejected' {EditPrivate (Join-Path $taskBoot 'source_manifest.json') {param($p) $r=ReadJson $p;$r.files[3]=$r.files[2];SaveJson $p $r;BindMetadata} $gate} $true 'role/path mismatch'
 Check 'complete_log_drift_rehashed_rejected' {EditPrivate (Join-Path $taskBoot 'full.log') {param($p) [IO.File]::AppendAllText($p,' private drift',$utf8);BindMetadata} $gate} $true 'independent complete log SHA'
 Check 'checker_drift_postconversion_rejected' {EditPrivate $taskBootChecker {param($p) [IO.File]::AppendAllText($p,"`n# private checker drift",$utf8)} {& $post}} $true 'Stale input'
 Check 'input_drift_postconversion_rejected' {EditPrivate (Join-Path $taskBoot 'source_verification.json') {param($p) [IO.File]::AppendAllText($p,' ',$utf8)} {& $post}} $true 'Stale input'
 Check 'release_copy_drift_postconversion_rejected' {EditPrivate $taskBootCopies[0].path {param($p) [IO.File]::AppendAllText($p,' ',$utf8)} {& $post}} $true 'Stale input'
 Check 'release_checker_copy_drift_postconversion_rejected' {EditPrivate (Join-Path $taskRelease 'boot_epoch/check_geometry_boot_epoch_evidence.ps1') {param($p) [IO.File]::AppendAllText($p,"`n# private archived checker drift",$utf8)} {& $post}} $true 'Stale input'
 # Boundary-only stubs test the real helper's typed/nonempty contract. They are
 # private scripts, not modifications or replacements of the production gate.
 $stub=Join-Path $out 'boundary_checker.ps1'
 [IO.File]::WriteAllText($stub,"param([string]`$WorkspaceRoot,[string]`$EvidenceDirectory)`n[pscustomobject]@{passed='false';inputs=@([pscustomobject]@{path=`$PSCommandPath;sha256=(Get-FileHash `$PSCommandPath).Hash})}",$utf8)
 Check 'helper_return_stringfalse_rejected' {Assert-BootEpochEquivalence $taskBoot $stub} $true 'Boot epoch contract proof failed'
 [IO.File]::WriteAllText($stub,"param([string]`$WorkspaceRoot,[string]`$EvidenceDirectory)`n[pscustomobject]@{passed=`$true;inputs=@()}",$utf8)
 Check 'helper_return_empty_inputs_rejected' {Assert-BootEpochEquivalence $taskBoot $stub} $true 'Boot epoch contract proof failed'
 # Exercise the actual copy block against missing/duplicate frozen bindings;
 # failures may leave only private partial release folders as useful evidence.
 Check 'copy_unbound_input_rejected' {
  $taskBootCheck=[pscustomobject]@{hashes=@($script:taskBootCheck.hashes|Where-Object {$_.path -ne (Join-Path $taskBoot 'result.json')});check=$script:taskBootCheck.check}
  $taskRelease=Join-Path $out 'release_unbound';New-Item -ItemType Directory -Path $taskRelease|Out-Null
  & $copy
 } $true 'Unbound or duplicate boot proof copy'
 Check 'copy_duplicate_input_rejected' {
  $taskBootCheck=[pscustomobject]@{hashes=@($script:taskBootCheck.hashes)+@($script:taskBootCheck.hashes|Where-Object {$_.path -eq (Join-Path $taskBoot 'result.json')});check=$script:taskBootCheck.check}
  $taskRelease=Join-Path $out 'release_duplicate';New-Item -ItemType Directory -Path $taskRelease|Out-Null
  & $copy
 } $true 'Unbound or duplicate boot proof copy'
 Check 'fixture_restored_postcheck_and_originals_unchanged' {& $post;Assert-Hashes $originalHashes}
 $success=$true
}catch{$failure=$_.Exception.ToString();throw}finally{
 # Freeze reviewed exporter/checker versions in both runtime result records;
 # end hashes must match start hashes, including the untouched actual proof.
 $endExporter=(Get-FileHash -LiteralPath $exporter).Hash;$endChecker=(Get-FileHash -LiteralPath $realChecker).Hash
 if($endExporter -cne $frozenExporter -or $endChecker -cne $frozenChecker){$success=$false;$failure='Exporter/checker changed during sidecar test'}
 $result=[ordered]@{schema_version='geometry-boot-epoch-exporter-tests/v1';passed=$success;powershell=$PSVersionTable.PSVersion.ToString();parser_errors=@($errors).Count;
  cases=@($records.ToArray());exporter_sha256=$frozenExporter;checker_sha256=$frozenChecker;exporter_sha256_after=$endExporter;checker_sha256_after=$endChecker;
  test_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;ast_blocks=@($blocks.ToArray());original_inputs=$originalHashes;fixture=$fixture;
  production_logs_byte_preserved=$true;fixture_logs_workspace_prefix_only=$true;no_native_or_hardware_executed=$true;failure=$failure}
 SaveJson (Join-Path $out 'test_results.json') $result
 [IO.File]::WriteAllText((Join-Path $out 'test.log'),($records|Format-Table name,passed,reason -AutoSize|Out-String -Width 220),$utf8)
 Write-Output ([pscustomobject]@{passed=$success;directory=$out;cases=$records.Count;powershell=$PSVersionTable.PSVersion.ToString()})
 if(-not $success){throw ("Boot exporter integration test failed: "+$failure)}
 Write-Host "BOOT_EPOCH_EXPORTER_TESTS_PASS cases=$($records.Count) PS=$($PSVersionTable.PSVersion)"
}
