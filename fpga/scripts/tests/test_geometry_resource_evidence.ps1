# Purpose: PS5.1/7 acceptance/rejection tests, mutating ONLY newly copied fixtures.
# No old proof or formal file is rewritten. Caller supplies a NEW artifact dir.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkspaceRoot,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$ResourceDirectory='fpga/build/resource_valid_parallel_20261007_1734')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
$out=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if(-not $out.StartsWith((Join-Path $root 'fpga/build')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Tests must write inside fpga/build'}
if(Test-Path -LiteralPath $out){throw 'OutputDirectory must be new'}
[IO.Directory]::CreateDirectory($out)|Out-Null
$validator=Join-Path $root 'fpga/scripts/check_geometry_resource_evidence.ps1'
$merge=$ResourceDirectory
$timing='fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476'
$manifest=Join-Path $root "$merge/resource_manifest.json"
$original=[IO.File]::ReadAllText($manifest)
$spec=$original|ConvertFrom-Json
$fixture=Join-Path $out 'fixture'
# Purpose: keep all historical negatives with the same old identities. Three
# exact historical archives resolve the old records, while current cache bytes
# and new proof inputs are copied separately from the new verified inventory.
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
$proofChecker='fpga/scripts/check_cache_valid_parallel_evidence.ps1'
$proof=& (Join-Path $root $proofChecker) -WorkspaceRoot $root -EvidenceDirectory (Join-Path $root $timing) -CheckPublishedEvidence
$extra=@($proof.files_after|ForEach-Object {$_.path})+@($proofChecker,"$timing/cache_valid_parallel_evidence.json",'fpga/build/cache_valid_parallel_20261007_171322_219/history/check_geometry_resource_evidence.ps1')
foreach($relative in $extra){
 $dest=Join-Path $fixture $relative
 [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))|Out-Null
 if(-not (Test-Path -LiteralPath $dest)){[IO.File]::Copy((Join-Path $root $relative),$dest,$false)}
}
$fm=Join-Path $fixture "$merge/resource_manifest.json"
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fm))|Out-Null
$encoding=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($fm,$original,$encoding)
$script:results=@()
function Check([string]$Name,[scriptblock]$Action,[bool]$Reject,[string]$Reason=''){
 $message=$null;$failed=$false
 try{& $Action|Out-Null}catch{$failed=$true;$message=$_.Exception.Message}
 if($failed -ne $Reject){throw "Unexpected outcome $Name : $message"}
 if($Reject -and $Reason -and $message -notmatch $Reason){throw "Wrong rejection $Name : $message"}
 $script:results += [pscustomobject]@{name=$Name;passed=$true;expected_rejection=$Reject;reason=$message}
 Write-Host "PASS $Name"
}
function ValidateFixture{& $validator -WorkspaceRoot $fixture -EvidenceDirectory (Join-Path $fixture $merge) -CacheTimingEquivalence (Join-Path $fixture $timing) -ValidateOnly}
function MutateFile([string]$Relative,[string]$Name,[switch]$Empty){
 $p=Join-Path $fixture $Relative
 try{
  if($Empty){[IO.File]::WriteAllBytes($p,[byte[]]@())}else{[IO.File]::AppendAllText($p,([Environment]::NewLine+'// stale fixture'),$encoding)}
  Check $Name {ValidateFixture} $true 'Stale (source/log|parallel-valid source/log)'
 }finally{[IO.File]::Copy((Join-Path $root $Relative),$p,$true)}
}
function MutateManifest([string]$Name,[scriptblock]$Change,[string]$Reason){
 $script:mut=$original|ConvertFrom-Json
 try{& $Change;[IO.File]::WriteAllText($fm,($script:mut|ConvertTo-Json -Depth 20),$encoding);Check $Name {ValidateFixture} $true $Reason}
 finally{[IO.File]::WriteAllText($fm,$original,$encoding)}
}
Check 'actual_positive' {& $validator -WorkspaceRoot $root -EvidenceDirectory (Join-Path $root $merge) -CacheTimingEquivalence (Join-Path $root $timing) -ValidateOnly} $false
Check 'copied_positive' {ValidateFixture} $false
MutateFile 'fpga/rtl/geometry/geometry_result_stream_writer.v' 'staleformal_writer'
MutateFile 'fpga/rtl/geometry/geometry_marker_overlay.v' 'staleformal_overlay'
MutateFile 'fpga/rtl/geometry/geometry_window_cache.v' 'staleformal_cache'
MutateFile 'fpga/build/cache_valid_parallel_20261007_171322_219/geometry_window_cache.golden.v' 'stalehistorical_0F_cache'
MutateFile "$timing/sources/geometry_window_cache.v" 'stalenew_snapshot'
MutateFile "$timing/compile.log" 'stalenew_compile'
MutateFile "$timing/cycle_stride2048_cache1024_seed987654321.log" 'stalenew_log'
MutateFile "$timing/cycle_stride32_cache64_seed20261007.log" 'emptynew_log' -Empty
MutateFile "$timing/result.json" 'stalenew_selfreported_pass'
MutateFile "$timing/sources.before.json" 'stalenew_before_manifest'
MutateFile "$timing/sources.after.json" 'stalenew_after_manifest'
MutateFile 'fpga/build/cache_tag_packed_20261007_131154_460/geometry_window_cache.v' 'stalecandidate'
MutateFile 'fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/tb_overlay_miter.log' 'stalelog'
MutateFile 'fpga/build/writer_fence_pipeline_20261007_125622_690/miter_final/simulation.log' 'emptylog' -Empty
MutateManifest 'empty_inventory' {$script:mut.files=@()} 'Incomplete finite file inventory'
MutateManifest 'passed_string_false' {$script:mut.passed='false'} 'typed boolean true'
MutateManifest 'passed_string_true' {$script:mut.passed='true'} 'typed boolean true'
MutateManifest 'passed_false' {$script:mut.passed=$false} 'typed boolean true'
MutateManifest 'missing_cycle_case' {$script:mut.matrix.cache_cycle=@($script:mut.matrix.cache_cycle|Select-Object -Skip 1)} 'cache_cycle incomplete matrix'
MutateManifest 'missing_scalar_case' {$script:mut.matrix.cache_scalar=@($script:mut.matrix.cache_scalar|Select-Object -Skip 1)} 'cache_scalar incomplete matrix'
MutateManifest 'wrong_writer_matrix' {$script:mut.matrix.writer.coincident_bits=255} 'writer coverage mismatch'
MutateManifest 'wrong_overlay_matrix' {$script:mut.matrix.overlay.original_bench_frames=241} 'overlay coverage mismatch'
MutateManifest 'unknown_schema_key' {$script:mut|Add-Member -NotePropertyName bogus -NotePropertyValue $true} 'manifest schema keys'
MutateManifest 'wrong_schema' {$script:mut.schema_version='geometry-resource-manifest/v0'} 'Wrong manifest schema'
MutateManifest 'rebaseline_sha' {$script:mut.files[0].sha256=('0'*64)} 'Freeze identity drift'
MutateManifest 'duplicate_file' {$script:mut.files[1]=$script:mut.files[0]} 'Duplicate file'
Check 'create_new_output' {& $validator -WorkspaceRoot $fixture -EvidenceDirectory (Join-Path $fixture $merge) -CacheTimingEquivalence (Join-Path $fixture $timing)} $false
Check 'validate_saved_positive' {ValidateFixture} $false
# Purpose: saved results are independent untrusted inputs. ValidateOnly must
# reject semantic/type drift even while the full underlying corpus is intact.
$published=Join-Path $fixture "$merge/resource_evidence.json"
$saved=[IO.File]::ReadAllText($published)
function MutatePublished([string]$Name,[scriptblock]$Change,[string]$Reason){
 $script:pub=$saved|ConvertFrom-Json
 try{& $Change;[IO.File]::WriteAllText($published,($script:pub|ConvertTo-Json -Depth 20),$encoding);Check $Name {ValidateFixture} $true $Reason}
 finally{[IO.File]::WriteAllText($published,$saved,$encoding)}
}
MutatePublished 'saved_passed_string_false' {$script:pub.passed='false'} 'typed boolean mismatch'
MutatePublished 'saved_passed_false' {$script:pub.passed=$false} 'typed boolean mismatch'
MutatePublished 'saved_stale_checker' {$script:pub.validator_sha256=('0'*64)} 'string mismatch'
MutatePublished 'saved_empty_logs' {$script:pub.logs_before=@()} 'array mismatch'
MutatePublished 'saved_missing_case' {$script:pub.matrix.cache_cycle=@($script:pub.matrix.cache_cycle|Select-Object -Skip 1)} 'array mismatch'
MutatePublished 'saved_extra_field' {$script:pub|Add-Member -NotePropertyName unexpected -NotePropertyValue 1} 'schema keys'
# Purpose: the mandatory proof publication is independently untrusted. Reject
# truthy strings, missing cases, unknown keys and an old PASS relabeled as new.
$timingPublication=Join-Path $fixture "$timing/cache_valid_parallel_evidence.json"
$timingSaved=[IO.File]::ReadAllText($timingPublication)
function MutateTimingPublished([string]$Name,[scriptblock]$Change,[string]$Reason){
 $script:tp=$timingSaved|ConvertFrom-Json
 try{& $Change;[IO.File]::WriteAllText($timingPublication,($script:tp|ConvertTo-Json -Depth 30),$encoding);Check $Name {ValidateFixture} $true $Reason}
 finally{[IO.File]::WriteAllText($timingPublication,$timingSaved,$encoding)}
}
MutateTimingPublished 'timing_saved_string_pass' {$script:tp.passed='true'} 'typed boolean mismatch'
MutateTimingPublished 'timing_saved_false_pass' {$script:tp.passed=$false} 'typed boolean mismatch'
MutateTimingPublished 'timing_saved_missing_case' {$script:tp.cases=@($script:tp.cases|Select-Object -Skip 1)} 'array mismatch'
MutateTimingPublished 'timing_saved_old_cache_sha' {$script:tp.candidate_sha256='0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385'} 'string mismatch'
MutateTimingPublished 'timing_saved_unknown_field' {$script:tp|Add-Member -NotePropertyName bypass -NotePropertyValue $true} 'schema keys'
# A replacement checker that returns a self-reported PASS must be rejected
# before execution, even when its own output would look superficially typed.
$checkerFixture=Join-Path $fixture $proofChecker
try{
 [IO.File]::WriteAllText($checkerFixture,'[pscustomobject]@{passed=$true;schema_version="cache-valid-parallel-evidence/v1"}',$encoding)
 Check 'fake_pass_checker_rejected' {ValidateFixture} $true 'Unreviewed parallel-valid checker'
}finally{[IO.File]::Copy((Join-Path $root $proofChecker),$checkerFixture,$true)}
try{
 [IO.File]::Move($timingPublication,$timingPublication+'.hidden')
 Check 'missing_mandatory_timing_publication' {ValidateFixture} $true 'Missing mandatory saved'
}finally{[IO.File]::Move($timingPublication+'.hidden',$timingPublication)}
Check 'refuse_overwrite' {& $validator -WorkspaceRoot $fixture -EvidenceDirectory (Join-Path $fixture $merge) -CacheTimingEquivalence (Join-Path $fixture $timing)} $true 'already exists'
# Recheck production corpus after all mutations of the disposable copy.
Check 'actual_unchanged_after_tests' {& $validator -WorkspaceRoot $root -EvidenceDirectory (Join-Path $root $merge) -CacheTimingEquivalence (Join-Path $root $timing) -ValidateOnly} $false
$result=[ordered]@{schema_version='geometry-resource-checker-tests/v1';passed=$true;powershell=$PSVersionTable.PSVersion.ToString();cases=$script:results;validator_sha256=(Get-FileHash -LiteralPath $validator -Algorithm SHA256).Hash;manifest_sha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash}
[IO.File]::WriteAllText((Join-Path $out 'test_results.json'),($result|ConvertTo-Json -Depth 10),$encoding)
Write-Host "RESOURCE_CHECKER_TESTS_PASS cases=$($script:results.Count) PS=$($PSVersionTable.PSVersion)"

