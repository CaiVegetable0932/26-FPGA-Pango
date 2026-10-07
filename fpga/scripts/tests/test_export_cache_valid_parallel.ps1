# Purpose: PS5.1/7 offline AST and extracted-function tests for the mandatory
# cache timing publication gate. Never execute exporter top-level/finalizer,
# PDS, conversion or hardware. Mutations affect only a newly created fixture.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,
 [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
$out=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if(-not $out.StartsWith((Join-Path $root 'fpga/build')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Output must be new under fpga/build'}
[IO.Directory]::CreateDirectory($out)|Out-Null
$exporter=Join-Path $root 'fpga/scripts/export_geometry_candidate.ps1'
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($exporter,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Exporter AST parse failed'}
$script:results=@()
function Test([string]$Name,[scriptblock]$Action,[bool]$Reject=$false,[string]$Reason=''){
 $failed=$false;$message=$null
 try{& $Action|Out-Null}catch{$failed=$true;$message=$_.Exception.Message}
 if($failed -ne $Reject -or ($Reject -and $Reason -and $message -notmatch $Reason)){throw "Unexpected $Name : $message"}
 $script:results+=[pscustomobject]@{name=$Name;passed=$true;expected_rejection=$Reject;reason=$message}
 Write-Host "PASS $Name"
}
Test 'mandatory_parameter' {
 $parameter=@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'CacheTimingEquivalence'})
 if($parameter.Count -ne 1 -or $parameter[0].Extent.Text -notmatch 'Mandatory\s*=\s*\$true' -or $parameter[0].DefaultValue){throw 'Timing parameter is not mandatory'}
}
# Purpose: verify actual AST calls precede native finalization and recur after
# conversions; a comment/string containing a function name cannot satisfy it.
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
$timingCalls=@($commands|Where-Object {$_.GetCommandName() -ceq 'Assert-CacheTimingEquivalence'})
$finalizer=@($commands|Where-Object {$_.Extent.Text -match '^&.*finalize_geometry_evidence\.ps1'})
$resourceCalls=@($commands|Where-Object {$_.GetCommandName() -ceq 'Assert-ResourceEquivalence'})
Test 'timing_preflight_postflight' {
 if($timingCalls.Count -ne 2 -or $finalizer.Count -ne 1 -or
  $timingCalls[0].Extent.StartOffset -ge $finalizer[0].Extent.StartOffset -or
  $timingCalls[1].Extent.StartOffset -le $finalizer[0].Extent.EndOffset){throw 'Missing timing pre/postflight'}
}
Test 'resource_mandatory_link' {
 if($resourceCalls.Count -ne 2){throw 'Missing resource pre/postflight'}
 foreach($call in $resourceCalls){if($call.Extent.Text -notmatch '\$taskTiming$'){throw 'Resource proof omitted timing directory'}}
}
# Import only four read-only gate functions. Their AST bodies contain no
# finalizer/converter/PDS commands; exporter top-level is never dot-sourced.
foreach($name in @('Resolve-Build','Assert-Hashes','Assert-CacheTimingEquivalence','Assert-ResourceEquivalence')){
 $function=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object {$_.Name -ceq $name})
 if($function.Count -ne 1 -or $function[0].Body.Extent.Text -match 'finalize_geometry|cdt_cfg|COMMS_SFC'){throw 'Unsafe selected gate function'}
 . ([scriptblock]::Create($function[0].Extent.Text))
}
$taskFpga=Join-Path $root 'fpga';$taskBuild=Join-Path $taskFpga 'build'
$timing=Join-Path $root 'fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476'
$checker=Join-Path $root 'fpga/scripts/check_cache_valid_parallel_evidence.ps1'
$resource=Join-Path $root 'fpga/build/resource_valid_parallel_20261007_1734'
$resourceChecker=Join-Path $root 'fpga/scripts/check_geometry_resource_evidence.ps1'
Test 'actual_cache_gate' {$script:proof=Assert-CacheTimingEquivalence $timing $checker}
Test 'actual_resource_gate' {Assert-ResourceEquivalence $resource $resourceChecker $timing}
Test 'wrong_directory_rejected' {Assert-CacheTimingEquivalence $resource $checker} $true 'Unreviewed parallel-valid evidence directory'
$encoding=New-Object Text.UTF8Encoding($false)
$fake=Join-Path $out 'fake_checker.ps1'
[IO.File]::WriteAllText($fake,'[pscustomobject]@{passed=$true;schema_version="cache-valid-parallel-evidence/v1";files_after=@()}',$encoding)
Test 'selfreported_pass_checker_rejected' {Assert-CacheTimingEquivalence $timing $fake} $true 'Unreviewed parallel-valid checker'
# Purpose: model exactly the exporter's finite source/log/checker copy loop,
# retain every original SHA and then verify copied bytes independently.
$copies=@();$index=0
foreach($record in $script:proof.hashes){
 $dest=Join-Path $out (('{0:D3}_' -f $index)+[IO.Path]::GetFileName($record.path))
 [IO.File]::Copy($record.path,$dest,$false)
 $copies+=[pscustomobject]@{source=$record.path;path=$dest;sha256=$record.sha256};$index++
}
Test 'complete_archive_hash_closure' {
 if($copies.Count -ne 57){throw 'Incomplete finite timing archive'}
 Assert-Hashes $script:proof.hashes;Assert-Hashes $copies
}
try{
 [IO.File]::AppendAllText($copies[3].path,'stale copied source',$encoding)
 Test 'stale_archive_rejected' {Assert-Hashes $copies} $true 'Stale input'
}finally{[IO.File]::Copy($copies[3].source,$copies[3].path,$true)}
Test 'original_and_archive_unchanged' {Assert-Hashes $script:proof.hashes;Assert-Hashes $copies}
$result=[ordered]@{schema_version='cache-valid-exporter-tests/v1';passed=$true;powershell=$PSVersionTable.PSVersion.ToString();
 exporter_sha256=(Get-FileHash -LiteralPath $exporter).Hash;cases=$script:results;archive=$copies;
 native_commands_executed=$false;hardware_verified=$false}
[IO.File]::WriteAllText((Join-Path $out 'test_results.json'),($result|ConvertTo-Json -Depth 15),$encoding)
Write-Host "CACHE_VALID_EXPORTER_TESTS_PASS cases=$($script:results.Count) PS=$($PSVersionTable.PSVersion)"
