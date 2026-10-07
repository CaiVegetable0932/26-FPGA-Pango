# Purpose: parse and execute ONLY the added resource exporter gate from its AST.
# Never execute exporter native finalizer/converter, PDS, or hardware commands.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,
 [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
$out=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if(-not $out.StartsWith((Join-Path $root 'fpga/build')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Tests must remain under build'}
if(Test-Path -LiteralPath $out){throw 'OutputDirectory must be new'}
[IO.Directory]::CreateDirectory($out)|Out-Null
$path=Join-Path $root 'fpga/scripts/export_geometry_candidate.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ($errors|Out-String)}
$source=[IO.File]::ReadAllText($path)
$param=@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'ResourceEquivalence'})
if($param.Count -ne 1 -or $param[0].Extent.Text -notmatch 'Mandatory=\$true'){throw 'ResourceEquivalence must be mandatory'}
$timingParam=@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'CacheTimingEquivalence'})
if($timingParam.Count -ne 1 -or $timingParam[0].Extent.Text -notmatch 'Mandatory=\$true'){throw 'CacheTimingEquivalence must be mandatory'}
# Purpose: execute actual production helpers, including the mandatory timing
# postflight now present in the same bounded resource recheck block.
foreach($name in @('Assert-Hashes','Assert-ResourceEquivalence','Assert-CacheTimingEquivalence')){
 $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw "Unique function missing: $name"}
 Invoke-Expression $nodes[0].Extent.Text
}
$merge='fpga/build/resource_valid_parallel_20261007_1734'
$timing='fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476'
$manifest=Join-Path $root "$merge/resource_manifest.json"
$spec=[IO.File]::ReadAllText($manifest)|ConvertFrom-Json
$fixture=Join-Path $out 'fixture';$enc=New-Object Text.UTF8Encoding($false)
# Purpose: preserve the old 116 identities using only the same three reviewed
# archives as the production checker; copy new current/cache proof separately.
$aliases=@{
 'fpga/rtl/geometry/geometry_window_cache.v'='fpga/build/cache_valid_parallel_20261007_171322_219/geometry_window_cache.golden.v'
 'fpga/sim/tb_geometry_window.sv'='fpga/build/cache_valid_parallel_20261007_171322_219/history/tb_geometry_window.sv'
 'fpga/scripts/sim_geometry_window.ps1'='fpga/build/cache_valid_parallel_20261007_171322_219/history/sim_geometry_window.ps1'
}
foreach($f in $spec.files){
 $relative=$f.path;if($aliases.ContainsKey($relative)){$relative=$aliases[$relative]}
 $dest=Join-Path $fixture $relative
 [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))|Out-Null
 [IO.File]::Copy((Join-Path $root $relative),$dest,$false)
}
# Purpose: independently validate the real saved 40-case proof, then relocate
# its finite 55 files and checker/publication byte-for-byte. Existing duplicate
# golden copies must match; no old log or metadata is rebased to new source.
$timingChecker='fpga/scripts/check_cache_valid_parallel_evidence.ps1'
$proof=& (Join-Path $root $timingChecker) -WorkspaceRoot $root -EvidenceDirectory (Join-Path $root $timing) -CheckPublishedEvidence
if($proof.files_after.Count -ne 55 -or $spec.files.Count -ne 116){throw 'Incomplete reviewed fixture inventory'}
$extra=@($proof.files_after|ForEach-Object {$_.path})+@($timingChecker,"$timing/cache_valid_parallel_evidence.json",'fpga/build/cache_valid_parallel_20261007_171322_219/history/check_geometry_resource_evidence.ps1')
foreach($relative in $extra){
 $dest=Join-Path $fixture $relative
 [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))|Out-Null
 if(Test-Path -LiteralPath $dest){
  if((Get-FileHash -LiteralPath $dest).Hash -cne (Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash){throw 'Duplicate fixture byte drift'}
 }else{[IO.File]::Copy((Join-Path $root $relative),$dest,$false)}
}
$directory=Join-Path $fixture $merge
[IO.Directory]::CreateDirectory($directory)|Out-Null
[IO.File]::Copy($manifest,(Join-Path $directory 'resource_manifest.json'),$false)
[IO.File]::Copy((Join-Path $root "$merge/resource_evidence.json"),(Join-Path $directory 'resource_evidence.json'),$false)
$checker=Join-Path $fixture 'fpga/scripts/check_geometry_resource_evidence.ps1'
[IO.File]::Copy((Join-Path $root 'fpga/scripts/check_geometry_resource_evidence.ps1'),$checker,$false)
$taskFpga=Join-Path $fixture 'fpga'
$taskTiming=Join-Path $fixture $timing
$taskTimingChecker=Join-Path $fixture $timingChecker
$taskTimingCheck=Assert-CacheTimingEquivalence $taskTiming $taskTimingChecker
$null=& $checker -WorkspaceRoot $fixture -EvidenceDirectory $directory -CacheTimingEquivalence $taskTiming -ValidateOnly -CheckPublishedEvidence
$script:cases=@()
function Check([string]$Name,[scriptblock]$Action,[bool]$Reject,[string]$Reason=''){
 $failed=$false;$message=$null
 try{& $Action|Out-Null}catch{$failed=$true;$message=$_.Exception.Message}
 if($failed -ne $Reject -or ($Reject -and $Reason -and $message -notmatch $Reason)){throw "Unexpected $Name : $message"}
 $script:cases += [pscustomobject]@{name=$Name;passed=$true;expected_rejection=$Reject;reason=$message}
 Write-Host "PASS $Name"
}
Check 'PS_parser_and_mandatory_param' {$null=$ast} $false
Check 'preflight_valid_saved_evidence' {$script:context=Assert-ResourceEquivalence $directory $checker $taskTiming} $false
# Execute the exact post-conversion recheck block independently of native tools.
$postStart=$source.IndexOf(' Assert-Hashes $taskResourceCheck.hashes',[StringComparison]::Ordinal)
$postEnd=$source.IndexOf(" if((Get-FileHash -LiteralPath "+'$env:COMMS_SBIT'+")",$postStart,[StringComparison]::Ordinal)
if($postStart -lt 0 -or $postEnd -le $postStart){throw 'Missing bounded post-conversion resource block'}
$post=[scriptblock]::Create($source.Substring($postStart,$postEnd-$postStart))
$taskResourceCheck=$script:context;$taskResource=$directory;$taskResourceChecker=$checker
$taskResourceCopies=@()
foreach($h in $taskResourceCheck.hashes){
 $dest=Join-Path $out ([IO.Path]::GetFileName($h.path))
 [IO.File]::Copy($h.path,$dest,$false)
 $taskResourceCopies += [pscustomobject]@{path=$dest;sha256=$h.sha256}
}
# Purpose: the extracted current postflight also checks the timing originals
# and copied bytes. Retain all 57 bound files in a separate numbered archive,
# preserving every existing resource positive/negative case without stubs.
$taskTimingCopies=@();$timingArchive=Join-Path $out 'timing_archive'
[IO.Directory]::CreateDirectory($timingArchive)|Out-Null
$index=0
foreach($h in $taskTimingCheck.hashes){
 $dest=Join-Path $timingArchive (('{0:D3}_' -f $index)+[IO.Path]::GetFileName($h.path))
 [IO.File]::Copy($h.path,$dest,$false)
 $taskTimingCopies+=[pscustomobject]@{path=$dest;sha256=$h.sha256};$index++
}
if($taskTimingCopies.Count -ne 57){throw 'Incomplete timing release fixture'}
Check 'post_conversion_recheck_and_copies' {& $post} $false
$published=Join-Path $directory 'resource_evidence.json';$saved=[IO.File]::ReadAllBytes($published)
Check 'missing_saved_evidence' {
 [IO.File]::Move($published,$published+'.held')
 try{Assert-ResourceEquivalence $directory $checker $taskTiming}finally{[IO.File]::Move($published+'.held',$published)}
} $true
Check 'saved_string_false_preflight' {
 $p=[Text.Encoding]::UTF8.GetString($saved)|ConvertFrom-Json;$p.passed='false'
 [IO.File]::WriteAllText($published,($p|ConvertTo-Json -Depth 20),$enc)
 try{Assert-ResourceEquivalence $directory $checker $taskTiming}finally{[IO.File]::WriteAllBytes($published,$saved)}
} $true 'typed boolean mismatch'
Check 'saved_stale_checker_preflight' {
 $p=[Text.Encoding]::UTF8.GetString($saved)|ConvertFrom-Json;$p.validator_sha256=('0'*64)
 [IO.File]::WriteAllText($published,($p|ConvertTo-Json -Depth 20),$enc)
 try{Assert-ResourceEquivalence $directory $checker $taskTiming}finally{[IO.File]::WriteAllBytes($published,$saved)}
} $true 'string mismatch'
Check 'saved_evidence_changed_during_conversion' {
 [IO.File]::AppendAllText($published,' ',$enc)
 try{& $post}finally{[IO.File]::WriteAllBytes($published,$saved)}
} $true 'Stale input'
$checkerBytes=[IO.File]::ReadAllBytes($checker)
Check 'checker_changed_during_conversion' {
 [IO.File]::AppendAllText($checker,([Environment]::NewLine+'# test drift'),$enc)
 try{& $post}finally{[IO.File]::WriteAllBytes($checker,$checkerBytes)}
} $true 'Stale input'
$copied=$taskResourceCopies[0].path;$copyBytes=[IO.File]::ReadAllBytes($copied)
Check 'release_copy_changed' {
 [IO.File]::AppendAllText($copied,' ',$enc)
 try{& $post}finally{[IO.File]::WriteAllBytes($copied,$copyBytes)}
} $true 'Stale input'
Check 'preflight_before_native_finalization' {
 if($source.IndexOf('$taskResourceCheck=Assert-ResourceEquivalence') -ge $source.IndexOf('$taskFinalized=&')){throw 'Preflight ordering'}
 if($postStart -le $source.IndexOf('$taskConversionEvidence | ConvertTo-Json')){throw 'Postflight ordering'}
 if($source -notmatch 'resource_equivalence=\[ordered\]@\{directory=\$taskResource'){throw 'Release manifest reference missing'}
} $false
$result=[ordered]@{schema_version='geometry-resource-exporter-tests/v1';passed=$true;powershell=$PSVersionTable.PSVersion.ToString();parser_errors=0;cases=$script:cases;exporter_sha256=(Get-FileHash -LiteralPath $path).Hash;checker_sha256=(Get-FileHash -LiteralPath $checker).Hash;test_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;resource_directory=$merge;timing_directory=$timing;historical_files=116;timing_files=55;timing_archive=$taskTimingCopies;no_native_or_hardware_executed=$true}
[IO.File]::WriteAllText((Join-Path $out 'test_results.json'),($result|ConvertTo-Json -Depth 10),$enc)
Write-Host "RESOURCE_EXPORTER_TESTS_PASS cases=$($script:cases.Count) PS=$($PSVersionTable.PSVersion)"

