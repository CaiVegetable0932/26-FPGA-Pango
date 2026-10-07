# Purpose: PS5.1/7 read-only exact finite proof gate for production packed 0F
# -> parallel-valid 69422B. Literal independently reviewed pins bind actual
# ModelSim compile/logs, source origins, snapshots and before/after manifests.
# A self-reported PASS, rebaselined inventory, stale source or omitted case fails.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$EvidenceDirectory,
 [string]$WorkspaceRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
 [switch]$Publish,[switch]$CheckPublishedEvidence)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Require($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Keys($Object,[string[]]$Expected,[string]$Label){
 Require ($null -ne $Object -and $Object -is [pscustomobject]) "$Label must be object"
 Require ((@($Object.PSObject.Properties.Name|Sort-Object)-join '|') -ceq (($Expected|Sort-Object)-join '|')) "$Label schema keys"
}
# Purpose: recursively compare all closed-schema values, retaining bool,
# integer and array types on PS5.1 and PS7; unknown keys are always rejected.
function Same($Actual,$Wanted,[string]$Label){
 if($null -eq $Wanted){Require ($null -eq $Actual) "$Label must be null";return}
 if($Wanted -is [bool]){Require ($Actual -is [bool] -and $Actual -eq $Wanted) "$Label typed boolean mismatch";return}
 if($Wanted -is [string]){Require ($Actual -is [string] -and $Actual -ceq $Wanted) "$Label string mismatch";return}
 if($Wanted -is [int] -or $Wanted -is [long]){Require (($Actual -is [int] -or $Actual -is [long]) -and $Actual -eq $Wanted) "$Label integer mismatch";return}
 if($Wanted -is [array]){
  Require ($Actual -is [array] -and $Actual.Count -eq $Wanted.Count) "$Label array mismatch"
  for($i=0;$i -lt $Wanted.Count;$i++){Same $Actual[$i] $Wanted[$i] "$Label[$i]"};return
 }
 $names=@();if($Wanted -is [Collections.IDictionary]){$names=@($Wanted.Keys)}else{$names=@($Wanted.PSObject.Properties.Name)}
 Keys $Actual $names $Label
 foreach($name in $names){Same $Actual.$name $Wanted.$name "$Label.$name"}
}
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
$directory=[IO.Path]::GetFullPath($EvidenceDirectory).TrimEnd('\','/')
$attempt='fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476'
Require ($directory -ceq [IO.Path]::GetFullPath((Join-Path $root $attempt))) 'Unreviewed parallel-valid evidence directory'
Require (-not ($Publish -and $CheckPublishedEvidence)) 'Publish and CheckPublishedEvidence are mutually exclusive'
function Full([string]$Relative){
 Require ($Relative -cmatch '^fpga/[A-Za-z0-9_./-]+$' -and $Relative -notmatch '(^|/)\.\.?(/|$)') 'Invalid proof path'
 $path=[IO.Path]::GetFullPath((Join-Path $root $Relative))
 Require ($path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Proof path escapes workspace'
 Require (Test-Path -LiteralPath $path -PathType Leaf) "Missing parallel-valid file: $Relative"
 return $path
}
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Read([string]$Relative){return [IO.File]::ReadAllText((Full $Relative))}
function Json([string]$Relative){return (Read $Relative|ConvertFrom-Json)}
# Filled only after inspecting the completed genuine compile and 40 logs.
$reviewedFiles=@'
[
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/geometry_window_cache.golden.v",
    "sha256": "0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385",
    "bytes": 14216,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources/geometry_window_cache.golden.v",
    "sha256": "0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385",
    "bytes": 14216,
    "kind": "input"
  },
  {
    "path": "fpga/rtl/geometry/geometry_window_cache.v",
    "sha256": "69422BF532261480BEB3EC2B1687D8D50BCB1BC14D54C3461C59A63441405635",
    "bytes": 15736,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources/geometry_window_cache.v",
    "sha256": "69422BF532261480BEB3EC2B1687D8D50BCB1BC14D54C3461C59A63441405635",
    "bytes": 15736,
    "kind": "input"
  },
  {
    "path": "fpga/sim/tb_cache_valid_parallel.sv",
    "sha256": "4F695BD926BB9076AB79BAC83A813ED3EA2C0944F8EA13BA3BEB3563747B8D0B",
    "bytes": 17216,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources/tb_cache_valid_parallel.sv",
    "sha256": "4F695BD926BB9076AB79BAC83A813ED3EA2C0944F8EA13BA3BEB3563747B8D0B",
    "bytes": 17216,
    "kind": "input"
  },
  {
    "path": "fpga/scripts/sim_cache_valid_parallel.ps1",
    "sha256": "6B4B9481E8EA123AA13F1A6004BCC305946A638628AD2BCDCEFA918F759177FA",
    "bytes": 5823,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources/sim_cache_valid_parallel.ps1",
    "sha256": "6B4B9481E8EA123AA13F1A6004BCC305946A638628AD2BCDCEFA918F759177FA",
    "bytes": 5823,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources/geometry_window_cache_golden.v",
    "sha256": "62E92266671A47E9DCD862401DD8DFE8155ADC07B5C4A6D32EF327DA193D211B",
    "bytes": 14223,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/compile.log",
    "sha256": "5B0C139D1261C9D6E0DD960ED7FAD423F1537149D0A02F5679DB299C2D0D29A6",
    "bytes": 259,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/vmap.log",
    "sha256": "EA95B183E03E12DD443E39F760683FFE784BAAD63CAD57145D0BCCEF17550925",
    "bytes": 61,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/modelsim.ini",
    "sha256": "6A1C4A91ADAD162AD9EB14AC90A2303358B11495246BCEF97C766F0489D5D4AB",
    "bytes": 75859,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources.before.json",
    "sha256": "5063BFEF0877D977F1C0CD9F096CCC22F307E8AEB08F5EBFE88925C40A8FF1D1",
    "bytes": 2358,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/sources.after.json",
    "sha256": "5063BFEF0877D977F1C0CD9F096CCC22F307E8AEB08F5EBFE88925C40A8FF1D1",
    "bytes": 2358,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/result.json",
    "sha256": "BB4F2F6335B0145F947EE7A03E35CB047695FFF5A07697052AF833E9100DB20B",
    "bytes": 8445,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache64_seed20261007.log",
    "sha256": "53CAB8E280E8507EB89785A719742A11FFE32010E128BC396E02A473D69CEFDB",
    "bytes": 1666,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache64_seed987654321.log",
    "sha256": "DB7111193FA504D372AB217EAA1F3EB76FFD3519F8EED2C8BA2F460AF645FF94",
    "bytes": 1668,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache128_seed20261007.log",
    "sha256": "8191027A5703595E4D5DC148C39AA02CF085178811F3DDCCB35E768FA5FA9829",
    "bytes": 1668,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache128_seed987654321.log",
    "sha256": "B1F3D292A240279DB76EC8D7BC77600E524B1634A3EEB920D505DBC787EE4241",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache256_seed20261007.log",
    "sha256": "038F86956BA641E2355B5D9F5E684594FE8EAFB219EA487AFEBA30A99D188D34",
    "bytes": 1668,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache256_seed987654321.log",
    "sha256": "3700B48F24E51663118BBEA44D69912170A50587340105C11B672F2689FB569F",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache512_seed20261007.log",
    "sha256": "DBBFEE8FBD36FC6CE7761F2AD9D795B5020DE0587226782385E57D50C0AF164B",
    "bytes": 1668,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache512_seed987654321.log",
    "sha256": "59748881B6FAFA98DF90C741BD14FF8CE712BBF60DF1CC2091A1B564921F1AFA",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache1024_seed20261007.log",
    "sha256": "FA03AE2E4676097C00B37B034992283CF910A196BB40BCA2EEB022FF16E8D303",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride32_cache1024_seed987654321.log",
    "sha256": "4830F6BAA639DCCC889B4ACEAC4BDD0D30A68CBC339D8AE5FEB9E1F48ECBDBC7",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache64_seed20261007.log",
    "sha256": "C82A9B213C412C03EBB05BC780177BF0674209A62DD1AAED7D6413B931E7CA2B",
    "bytes": 1668,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache64_seed987654321.log",
    "sha256": "4B850033BED4C0C4A3AC5A5835F10F5003C7C40E48E343F8A6DBEDD2DEBE46F4",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache128_seed20261007.log",
    "sha256": "9193799C7E497A70704BFA71974BC662C9C52E49C133AB49830E5CBC70F5847D",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache128_seed987654321.log",
    "sha256": "5B0865329C898713D49D9CA09C4BCBDB83D91E5F40D0AAF384A20AC2B9162102",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache256_seed20261007.log",
    "sha256": "BA35010191FBD97B67BF34F02EA227D5CB9BFF625D9B545426E8D0A282B6C769",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache256_seed987654321.log",
    "sha256": "E1D4C535D7F0507E92C809819A1A3DFEE914A1A5475DF2658CD3F81CD6A806EA",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache512_seed20261007.log",
    "sha256": "601C0EC979456ADD329648A4D28D9F9C68A22CBCEF31AECD48AFA519D6F10F17",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache512_seed987654321.log",
    "sha256": "B33C47DD7DF94A30D64F72A7EECE5FCEA0E359D99A24D8EB548A2F48CFE0A94C",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache1024_seed20261007.log",
    "sha256": "C6A7AD14B6B8D7D3E2864220289EEE34DEF178CACF9448A79B1FFAD87C460DAE",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride128_cache1024_seed987654321.log",
    "sha256": "8AC81D76221EA7EE5CF332936597309EB778720654561542EB64FD383B04EB0E",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache64_seed20261007.log",
    "sha256": "F357D77F5C4F50F9EBD83F3389D88586D88B7962697AA60234F6A64E6D8E795B",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache64_seed987654321.log",
    "sha256": "9A0B4AE402746134CC08D7D8210ACA21AB2F3CF3DFF59B5ECCE799FE6B276AFE",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache128_seed20261007.log",
    "sha256": "E1734AA69D2DB6A599EADDB682334F4A7F833F2CFC8D9FABFB44BC39B6621E55",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache128_seed987654321.log",
    "sha256": "1F0F051D82D79B230B977BA269A5A89A9021387A264576B5E1DC372905A0E62E",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache256_seed20261007.log",
    "sha256": "DC2782E1B5BEEDEC9AC1245A7AD97D3D040B8FCD37F1B63F639AEDF9DDA94B48",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache256_seed987654321.log",
    "sha256": "FAA67DF3360342361C36301809A6898556FF63C777C3C608B51187783485B21B",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache512_seed20261007.log",
    "sha256": "5E1948C440DA668F3DA2E4F85C54F063214B1CF54FFE18D1BC23E2F3F340E6E5",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache512_seed987654321.log",
    "sha256": "F40C55CBEF5826F3F5B4586F95007D9EB63BE304CF9F9AF8A06501AB74D9960F",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache1024_seed20261007.log",
    "sha256": "3C1211300CC1D421FB0CB66438B695CF87F8B61871C62BD6F3E51D7669C77C8D",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride1536_cache1024_seed987654321.log",
    "sha256": "F3DFAA17CEC78096E72A4D0BB7E1AFF2E527674EC95EE052B4513940D739DCDB",
    "bytes": 1676,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache64_seed20261007.log",
    "sha256": "F64BBA2F6393EC377EE1176BB907D660C6A1E5116E1E17D4284EB3477F733A60",
    "bytes": 1670,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache64_seed987654321.log",
    "sha256": "5AE47817C9ED6BE0BF82554DB773F4D1BEBB9CFBA26EEF46A5CBD9B31BF99D5E",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache128_seed20261007.log",
    "sha256": "89186A2AFAD6C5B5F676FB6D292ED61004699948890E7D4AD55DEC07A6EDAF90",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache128_seed987654321.log",
    "sha256": "AFB32DB80B040260A15B26B9E9F5709FF6AA64C1C6455FEFEDEFBC549F2E9C62",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache256_seed20261007.log",
    "sha256": "EAE2CCADCFD1E398AEFD8D8804D71CDFA5446D2356102111541C1225D789AAE9",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache256_seed987654321.log",
    "sha256": "D72093D0BFF66F2BA0945DF03A90E00931CDC1111F8753AB6172ECAC748A52AD",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache512_seed20261007.log",
    "sha256": "EFE08DC84B75AB593529586FBF8B03C2C1ED5C980C0674D7FBCCB9115067A4C3",
    "bytes": 1672,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache512_seed987654321.log",
    "sha256": "8D482A5416762807C897440640A747BAA1136669CB9A311B057EFD6CA5A50E5E",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache1024_seed20261007.log",
    "sha256": "0D4E70F07B97B303394971DEDE6DD2A0D7556B8C76E4B8C6CFBC57224EE31C1F",
    "bytes": 1674,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476/cycle_stride2048_cache1024_seed987654321.log",
    "sha256": "66E3CF007A9F64576A99A2EBDA9504E8354D7834641ED98189E9F224EABB4079",
    "bytes": 1676,
    "kind": "log"
  }
]
'@|ConvertFrom-Json
function Snapshot{
 Require ($reviewedFiles.Count -eq 55) 'Incomplete reviewed inventory'
 $items=@()
 foreach($file in $reviewedFiles){
  Keys $file @('path','sha256','bytes','kind') 'reviewed file'
  $path=Full $file.path
  Require ((Get-Item -LiteralPath $path).Length -eq $file.bytes -and (Digest $path) -ceq $file.sha256) "Stale parallel-valid source/log: $($file.path)"
  $items+=[pscustomobject][ordered]@{path=$file.path;sha256=$file.sha256;bytes=$file.bytes;kind=$file.kind}
 }
 return $items
}
$before=@(Snapshot)
# Purpose: reconstruct all candidate bytes from 0F using exactly three reviewed
# literal substitutions. No comment stripping, regex code rewriting or changed
# RAM/control/reset/address logic is accepted. Golden fixture only renames top.
$deltas=@'
[
  {
    "old": "// Nine simultaneous synchronous byte lookups replace nine serialized",
    "new": "// Timing-first: register request and replay validity in parallel, then select\n// the saved bit after that SAME edge. This removes replay control from the\n// large validity mux without an extra cycle, a changed RAM address or byte.\n// Nine simultaneous synchronous byte lookups replace nine serialized"
  },
  {
    "old": "  reg left_valid,right_valid;\n",
    "new": "  // Purpose: the native23 critical path was frame start -> replay -> address\n  // mux -> 1024:1 FF-valid lookup. Two parallel lookups move only the one-bit\n  // selection AFTER the existing register boundary. Keep all five registers\n  // here so retiming cannot reconstruct that pre-register serial dependency.\n  // No reset is added: as before, these snapshots are meaningful only after\n  // a lookup and otherwise hold, including backpressure and invalid sources.\n  (* syn_preserve=1, syn_allow_retiming=0 *) reg valid_replay_q;\n  (* syn_preserve=1, syn_allow_retiming=0 *) reg left_request_valid_q,right_request_valid_q;\n  (* syn_preserve=1, syn_allow_retiming=0 *) reg left_replay_valid_q,right_replay_valid_q;\n  wire left_valid=valid_replay_q?left_replay_valid_q:left_request_valid_q;\n  wire right_valid=valid_replay_q?right_replay_valid_q:right_request_valid_q;\n"
  },
  {
    "old": "  // Port B supplies the possible crossing payload and its tag in one read.\n  always @(posedge clk)if(lookup_enable)begin\n   right_word_q<=data[right_slot];\n   left_valid<=valids[left_slot];right_valid<=valids[right_slot];\n  end\n",
    "new": "  // Port B still uses the original selected address for payload/tag. In\n  // parallel, BOTH validity addresses sample the same pre-edge valid array;\n  // the registered selector chooses exactly the bit the old mux sampled.\n  // This preserves old-data semantics on fills and idle-only invalidation.\n  always @(posedge clk)if(lookup_enable)begin\n   right_word_q<=data[right_slot];\n   valid_replay_q<=replay;\n   left_request_valid_q<=valids[cache_slot(lanes[row*3].address)];\n   right_request_valid_q<=valids[cache_slot(lanes[row*3+2].address)];\n   left_replay_valid_q<=valids[cache_slot(a_address[row*3])];\n   right_replay_valid_q<=valids[cache_slot(a_address[row*3+2])];\n  end\n"
  }
]
'@|ConvertFrom-Json
$golden='fpga/build/cache_valid_parallel_20261007_171322_219/geometry_window_cache.golden.v'
$current='fpga/rtl/geometry/geometry_window_cache.v'
$reconstructed=Read $golden
foreach($delta in $deltas){
 Require (([regex]::Matches($reconstructed,[regex]::Escape($delta.old))).Count -eq 1) 'Nonunique exact timing delta'
 $reconstructed=$reconstructed.Replace($delta.old,$delta.new)
}
Require ($reconstructed -ceq (Read $current)) 'Candidate differs beyond exact three timing delta blocks'
Require ((Read $golden).Replace('module geometry_window_cache #','module geometry_window_cache_golden #') -ceq (Read "$attempt/sources/geometry_window_cache_golden.v")) 'Production golden top-only rename drift'
# Purpose: the runner compiles the frozen copies, not the live evolving source.
# All four original sources and all five snapshots are finite, independently
# pinned and checked in both source manifests; duplicate/extra roles fail.
$sourceRecords=@()
foreach($pair in @(
 [pscustomobject]@{role='golden';origin=$golden;copy='geometry_window_cache.golden.v'},
 [pscustomobject]@{role='candidate';origin=$current;copy='geometry_window_cache.v'},
 [pscustomobject]@{role='bench';origin='fpga/sim/tb_cache_valid_parallel.sv';copy='tb_cache_valid_parallel.sv'},
 [pscustomobject]@{role='runner';origin='fpga/scripts/sim_cache_valid_parallel.ps1';copy='sim_cache_valid_parallel.ps1'})){
 foreach($p in @($pair.origin,"$attempt/sources/$($pair.copy)")){
  $bound=@($before|Where-Object {$_.path -ceq $p});Require ($bound.Count -eq 1) 'Missing finite source pin'
  $sourceRecords+=[pscustomobject][ordered]@{role=$pair.role;path=$p;sha256=$bound[0].sha256;bytes=$bound[0].bytes}
 }
 Require ((Digest (Full $pair.origin)) -ceq (Digest (Full "$attempt/sources/$($pair.copy)"))) 'Snapshot-origin byte binding failed'
}
$fixture=@($before|Where-Object {$_.path -ceq "$attempt/sources/geometry_window_cache_golden.v"})
Require ($fixture.Count -eq 1) 'Missing renamed golden pin'
$sourceRecords+=[pscustomobject][ordered]@{role='renamed_golden';path=$fixture[0].path;sha256=$fixture[0].sha256;bytes=$fixture[0].bytes}
$sourceSchema=[ordered]@{schema_version='cache-valid-parallel-sources/v1';files=$sourceRecords}
Same (Json "$attempt/sources.before.json") $sourceSchema 'sources.before'
Same (Json "$attempt/sources.after.json") $sourceSchema 'sources.after'
$compile=Read "$attempt/compile.log"
Require ($compile -notmatch '\*\* (Error|Fatal)' -and $compile -match 'ModelSim SE-64 vlog 10\.1c') 'Actual compile tool/failure'
$modules=@([regex]::Matches($compile,'(?m)^-- Compiling module (\w+)')|ForEach-Object {$_.Groups[1].Value}|Sort-Object)
Require (($modules-join '|') -ceq 'geometry_window_cache|geometry_window_cache_golden|tb_cache_valid_parallel') 'Actual compile units mismatch'
# Purpose: enforce exact Cartesian cases and genuinely executed logs. All logs
# are literal SHA-pinned, load both caches and the miter with +acc, contain ONE
# finite PASS and no failures. Metrics enforce initial-X, holds and every hazard.
$cases=@();$metrics=@()
$fields=@('stride','cache_words','seed','requests','cycles','accepted','emitted','reads','promotions','replays','stalls','wrong_slot_rejects','tag_commits','grant_replies','fault_cases','initial_x_checks','valid_checks','lookup_checks','hold_checks','reset_cases','queued_checks','fill_checks','inactive_xz_cases','pre_checks','post_checks')
foreach($stride in @(32,128,1536,2048)){foreach($words in @(64,128,256,512,1024)){foreach($seed in @(20261007,987654321)){
 $name="cycle_stride$($stride)_cache$($words)_seed$($seed).log"
 $log=Read "$attempt/$name"
 Require ($log -notmatch '\*\* (Error|Fatal)|CACHE_VALID_\w*(FAIL|TIMEOUT)') "Miter failure: $name"
 Require ($log.Contains('-voptargs=+acc') -and $log.Contains("-gSEED=$seed") -and $log.Contains("-gSTRIDE=$stride") -and $log.Contains("-gCACHE_WORDS=$words")) 'Actual simulation command mismatch'
 foreach($unit in @('tb_cache_valid_parallel','geometry_window_cache','geometry_window_cache_golden')){
  Require ($log.Contains("# Loading work.$unit(fast)")) "Actual loaded unit missing: $unit"
 }
 $pattern='(?m)^# CACHE_VALID_PARALLEL_PASS '+(@($fields|ForEach-Object {"$_=(?<$_>[0-9]+)"})-join ' ')+'\r?$'
 $lines=[regex]::Matches($log,$pattern)
 Require ($lines.Count -eq 1 -and ([regex]::Matches($log,'CACHE_VALID_PARALLEL_PASS')).Count -eq 1) "Missing/duplicate finite PASS: $name"
 $metric=[ordered]@{}
 foreach($field in $fields){$metric[$field]=[int]$lines[0].Groups[$field].Value}
 Require ($metric.stride -eq $stride -and $metric.cache_words -eq $words -and $metric.seed -eq $seed -and $metric.requests -eq 2048) 'PASS matrix identity mismatch'
 Require ($metric.initial_x_checks -eq 6 -and $metric.fault_cases -eq 6 -and $metric.reset_cases -eq 10 -and $metric.inactive_xz_cases -eq 1) 'Missing reset/fault/four-state coverage'
 foreach($field in @('cycles','accepted','emitted','reads','promotions','replays','stalls','tag_commits','grant_replies','lookup_checks','hold_checks','queued_checks','fill_checks')){
  Require ($metric[$field] -gt 0) "Missing executed coverage: $field"
 }
 Require ($metric.accepted -ge 2048 -and $metric.pre_checks -eq $metric.cycles -and $metric.post_checks -eq $metric.cycles -and $metric.valid_checks -eq 3*$metric.cycles -and $metric.lookup_checks+$metric.hold_checks -eq $metric.valid_checks) 'Incomplete raw cycle comparison'
 if($stride -eq 2048 -and $words -ge 256){Require ($metric.wrong_slot_rejects -gt 0) 'Missing compact wrong-slot exercise'}
 $cases+=[pscustomobject][ordered]@{stride=$stride;cache_words=$words;seed=$seed;requests=2048;log=$name;passed=$true}
 $metrics+=[pscustomobject]$metric
}}}
$runSchema=[ordered]@{schema_version='cache-valid-parallel-run/v1';passed=$true;clock_period_ns=8;
 simulator='ModelSim SE-64 10.1c';golden_sha256='0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385';
 candidate_sha256='69422BF532261480BEB3EC2B1687D8D50BCB1BC14D54C3461C59A63441405635';
 sources_unchanged=$true;cases=$cases;formal_proof=$false;pds_run=$false;hardware_verified=$false;
 four_state_scope='Raw case-equality including initial X and inactive-coordinate X/Z; active controls and used addresses are binary.'}
Same (Json "$attempt/result.json") $runSchema 'result'
$after=@(Snapshot)
$currentPin=@($after|Where-Object {$_.path -ceq $current})
Require ($currentPin.Count -eq 1) 'Missing unique current-source pin'
$result=[ordered]@{schema_version='cache-valid-parallel-evidence/v1';passed=$true;directory=$attempt;
 validator_sha256=(Digest $PSCommandPath);current_source=$currentPin[0];golden_sha256=$runSchema.golden_sha256;
 candidate_sha256=$runSchema.candidate_sha256;clock_period_ns=8;cases=$cases;metrics=$metrics;
 files_before=$before;files_after=$after;sources_unchanged=$true;formal_proof=$false;timing_verified=$false;hardware_verified=$false;
 four_state_scope=$runSchema.four_state_scope;
 limitations=@('Bounded 40-case simulation; not unbounded formal equivalence.','Physical setup/hold, resource changes and hardware are outside this proof.','Active X/Z controls/selectors/used addresses are outside the binary transaction contract; raw initial X and inactive coordinates are compared without masks.')}
$publication=Join-Path $directory 'cache_valid_parallel_evidence.json'
if($CheckPublishedEvidence -or (Test-Path -LiteralPath $publication -PathType Leaf)){
 Require (-not $Publish) 'Refuse overwrite existing parallel-valid publication'
 Require (Test-Path -LiteralPath $publication -PathType Leaf) 'Missing mandatory saved parallel-valid evidence'
 $sha=Digest $publication
 Same ([IO.File]::ReadAllText($publication)|ConvertFrom-Json) $result 'published proof'
 Require ((Digest $publication) -ceq $sha) 'Publication changed during validation'
}
if($Publish){
 $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($result|ConvertTo-Json -Depth 30))
 $stream=[IO.File]::Open($publication,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}
[pscustomobject]$result

