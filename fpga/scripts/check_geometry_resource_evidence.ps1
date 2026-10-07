# Purpose: preserve all 116 reviewed historical writer/overlay/packed-cache
# identities, then require a separate exact 0F->69422B same-cycle timing proof.
# PS 5.1/7 compatible. No EDA invocation; legacy absolute baseline paths are
# historical identities after merge, not assertions about current formal RTL.
# Only a NEW resource_evidence.json may be created; -ValidateOnly writes nothing.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$EvidenceDirectory,
 [Parameter(Mandatory=$true)][string]$CacheTimingEquivalence,
 [string]$WorkspaceRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
 [switch]$ValidateOnly,[switch]$CheckPublishedEvidence)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Require($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Keys($Object,[string[]]$Expected,[string]$Label){
 Require ($null -ne $Object -and $Object -is [pscustomobject]) "$Label must be an object"
 Require ((@($Object.PSObject.Properties.Name|Sort-Object)-join '|') -ceq (($Expected|Sort-Object)-join '|')) "$Label schema keys"
}
function TrueBoolean($Value,[string]$Label){Require ($Value -is [bool] -and $Value -eq $true) "$Label must be typed boolean true"}
function FalseBoolean($Value,[string]$Label){Require ($Value -is [bool] -and $Value -eq $false) "$Label must be typed boolean false"}
function Integer($Value,[string]$Label){Require (($Value -is [int] -or $Value -is [long]) -and $Value -gt 0) "$Label must be positive integer"}
$root=[IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\','/')
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory).TrimEnd('\','/')
Require ($evidence.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'EvidenceDirectory must be inside WorkspaceRoot'
# Purpose: the old current-path records retain their OLD identities and hashes.
# Three finite archives resolve those historical identities after production
# cache/affected bench changes. No arbitrary path remapping or hash rebaseline.
# The original checker itself is also preserved (SHA 26C44C1C...384BEDF).
$historicalBindings=[ordered]@{
 'fpga/rtl/geometry/geometry_window_cache.v'='fpga/build/cache_valid_parallel_20261007_171322_219/geometry_window_cache.golden.v'
 'fpga/sim/tb_geometry_window.sv'='fpga/build/cache_valid_parallel_20261007_171322_219/history/tb_geometry_window.sv'
 'fpga/scripts/sim_geometry_window.ps1'='fpga/build/cache_valid_parallel_20261007_171322_219/history/sim_geometry_window.ps1'
}
function Full([string]$Relative){
 Require ($Relative -cmatch '^fpga/[A-Za-z0-9_./-]+$' -and $Relative -notmatch '(^|/)\.\.?(/|$)') "Invalid relative path: $Relative"
 if($historicalBindings.Contains($Relative)){$Relative=$historicalBindings[$Relative]}
 $p=[IO.Path]::GetFullPath((Join-Path $root $Relative))
 Require ($p.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Path escapes workspace'
 Require (Test-Path -LiteralPath $p -PathType Leaf) "Missing evidence: $Relative"
 return $p
}
function Read([string]$Relative){return [IO.File]::ReadAllText((Full $Relative))}
function Json([string]$Relative){return (Read $Relative|ConvertFrom-Json)}
function Digest([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
# Mandatory typed fresh validation precedes historical evidence. A saved PASS
# alone, or old packed/compact logs, cannot qualify current timing-changed bytes.
$timingChecker=Join-Path $root 'fpga/scripts/check_cache_valid_parallel_evidence.ps1'
$timingCheckerSha=Digest $timingChecker
Require ($timingCheckerSha -ceq '00AB65C38870AFD5B239C30B01716F40F51CA61C282E57F56D5CB091C843EBA5') 'Unreviewed parallel-valid checker'
$cacheProof=& $timingChecker -WorkspaceRoot $root -EvidenceDirectory $CacheTimingEquivalence -CheckPublishedEvidence
TrueBoolean $cacheProof.passed 'parallel-valid proof'
Require ($cacheProof.schema_version -ceq 'cache-valid-parallel-evidence/v1') 'Wrong parallel-valid proof schema'
Require ((Digest (Full 'fpga/build/cache_valid_parallel_20261007_171322_219/history/check_geometry_resource_evidence.ps1')) -ceq '26C44C1C27ACB751C79CF5A9933BD1EDADB9D9E6116A0E5560A05A41D384BEDF') 'Historical checker backup drift'
# A closed, finite schema with independent reviewed hashes. Manifest rebaselining
# cannot relax this gate; file identities/types/count and Cartesian cases are exact.
$expectedFiles=@'
[
  {
    "path": "fpga/rtl/geometry/geometry_result_stream_writer.v",
    "sha256": "7356D31B83139E69C4EA116818989CD6A73D09C86A36503CFF7743D9A21F447F",
    "bytes": 6018,
    "kind": "input"
  },
  {
    "path": "fpga/rtl/geometry/geometry_marker_overlay.v",
    "sha256": "EE323443B16C2C3C5D6EC02EF4AC50E65976C06C36F4B47990C87DA0ECF2342D",
    "bytes": 5038,
    "kind": "input"
  },
  {
    "path": "fpga/rtl/geometry/geometry_window_cache.v",
    "sha256": "0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385",
    "bytes": 14216,
    "kind": "input"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/golden.v",
    "sha256": "AEA9E0A58449562DA2B83DA554ED845F24E3C014FB43277D7629E7F64528D3E6",
    "bytes": 4995,
    "kind": "input"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/golden_renamed.v",
    "sha256": "6D4C91425E5B0CC36BAEC79EBEF5260EACF5C6C768C45F42AF09CA58F9A38900",
    "bytes": 5016,
    "kind": "input"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/candidate_frozen.v",
    "sha256": "7356D31B83139E69C4EA116818989CD6A73D09C86A36503CFF7743D9A21F447F",
    "bytes": 6018,
    "kind": "input"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/tb_writer_fence_miter.sv",
    "sha256": "D11FC69A399BB7EA50962BABAE6F7D19DE3517A6CA490A92CE003F3E9EB88923",
    "bytes": 11297,
    "kind": "input"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/run_miter.ps1",
    "sha256": "16E12A58B2D9CF9587E95AE240BAE21749FA57FD7C8EBF4EF1FC9F31D3915E9B",
    "bytes": 3498,
    "kind": "input"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/writer_miter_evidence.json",
    "sha256": "007DCB7F27CABCD8DE983130E3266FF33475F6F00C1CAD27F7B32680ABBB44AA",
    "bytes": 2135,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/miter_final/compile.log",
    "sha256": "796BA5587637E633282243C10C313A8F78CC7560F185322201F0D7A72664E70C",
    "bytes": 851,
    "kind": "log"
  },
  {
    "path": "fpga/build/writer_fence_pipeline_20261007_125622_690/miter_final/simulation.log",
    "sha256": "7930F443872351EB0C92A0C8009FF17963F785B794889EAA64F65235A71C38E5",
    "bytes": 1566,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/candidate.v",
    "sha256": "EE323443B16C2C3C5D6EC02EF4AC50E65976C06C36F4B47990C87DA0ECF2342D",
    "bytes": 5038,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/golden.v",
    "sha256": "CD2E78DD17221DC3EDD5E9C8E111709EC4A4802FDC71823AB2CAF92C7A7A200B",
    "bytes": 4394,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/golden_fixture.v",
    "sha256": "579E0AEF3F864CB5099BF85408A8B57F81CE1A76E4E1349783FAB54642CB8FDE",
    "bytes": 4401,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/geometry_marker_catalog.v",
    "sha256": "32229E1B4070C27958224DA3CEC09322EF68537B7BF4A83AFF6171B2DB1E4B61",
    "bytes": 1543,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/marker_golden.hex",
    "sha256": "1979C9EBA5D7BB039604D3C51F37594050B50E7D8ECB58FE90193A8C32630497",
    "bytes": 1080,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/tb_overlay_miter.sv",
    "sha256": "FA71DE37663E3D1BA460F47CBB2869797E5667F640666FCBFB83EDBB9A057A8A",
    "bytes": 3657,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/tb_geometry_marker_overlay.sv",
    "sha256": "95017BA2A6634F7BB91F9BE3CBBABB8CF7731073A674367738B996D65D86F1EE",
    "bytes": 4061,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/run_sim_fresh.ps1",
    "sha256": "D7396A9122788FBA8608E60D773BA8C881ECEB20D87D77FFD8A8F504500717C8",
    "bytes": 2078,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/proof_sources.json",
    "sha256": "71083EE325722FD2D150E4087F60E6AA11725D2C481DB3143843A2EA0A53881B",
    "bytes": 3437,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/compile.log",
    "sha256": "C0AC86C651C68F63953550787CDCFFE80FECD991CBFA11C7DB9C4DFD4761CB1A",
    "bytes": 371,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/tb_overlay_miter.log",
    "sha256": "EC2521A44316BC42C431505FB55A6E34F2F5EC05F0849DE88F75C072F488464C",
    "bytes": 898,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/tb_geometry_marker_overlay.log",
    "sha256": "8510B9821BF50E4AEEB5F24A6E4765795A89AAF56116977A6829AC76E627D5E9",
    "bytes": 895,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/result.json",
    "sha256": "3EDC2376C10005ED617864341EFC62699CE1B1356F1B94B760763F332A2CCDD3",
    "bytes": 159,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/marker_golden.hex",
    "sha256": "1979C9EBA5D7BB039604D3C51F37594050B50E7D8ECB58FE90193A8C32630497",
    "bytes": 1080,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/sim_verified_20261007_132421_601/run_sources.json",
    "sha256": "D7ABD93E42AA4E985A421DDCA5650E2C357ED3C3D1D7F2593967601D5CF1280F",
    "bytes": 498,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/geometry_window_cache.compact_golden.v",
    "sha256": "B991CFE6D48F920ED11C4B9B2FFF3C2B45764DE022C18B9AC75B3899C9D2B7FC",
    "bytes": 13322,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/geometry_window_cache.v",
    "sha256": "68DD323676483D3EE00EAFABD49575BD64307D4D4ABFB35434D5796D7D762D60",
    "bytes": 14212,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/geometry_window_cache_packed.v",
    "sha256": "F89671831853C0E5E429CEB33F4CF30B3DE5F7041F8F5EAB2DA7C1778AF1F10F",
    "bytes": 14219,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/tb_cache_packed_cycle.sv",
    "sha256": "487682C5616AADAC3AFD2D9621E498051DDEAF9E631DA32D4BC6C4E2C61767A3",
    "bytes": 13158,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/run_cycle_miter.ps1",
    "sha256": "973C687981295E04E96D6635AFF7BD156915382749EEDBF0ABA8F8140EB3C075",
    "bytes": 3170,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/prepare_test_fixtures.ps1",
    "sha256": "A4A16E02FBEB8AD82D540346354979F4E0F2C9445C00A69E0D380F502AA3F679",
    "bytes": 3025,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/run_existing_window.ps1",
    "sha256": "1CADB21AF579303DAA41C68831B285600A52DE7485D219D5755C936BF0F5F772",
    "bytes": 1588,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/handoff.json",
    "sha256": "2447648CEBB4A5E23E3733010F622594457C599EE517F9F3BD20EDED6257E85B",
    "bytes": 12988,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/sources.json",
    "sha256": "17CFC34ED79CC729B1F821B1A3D19631399C9163740E6430888EB1F2C7BA4810",
    "bytes": 1294,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/geometry_window_cache_golden.v",
    "sha256": "E18E7DF3F36BB41FB4D060C163B4D0ED6FB324A630BBCBFED23DECA583B0ADC0",
    "bytes": 13329,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/compile.log",
    "sha256": "6141F4E6E4943FE7DDA071A95EE128E5CEF8CFF69AF72DD0AD136ABD61AF6C46",
    "bytes": 256,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/result.json",
    "sha256": "2FB80FAF9EE13542C9DBCEF5AD3451F0968E8DA8D7C3ED3FC44425215D03A6B0",
    "bytes": 2812,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/sources.json",
    "sha256": "AEFA991D8F90283F90155197333E66BC0FE8B2224BFD0E8396968549F2DBBDA4",
    "bytes": 1916,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/geometry_gray_sampler_golden.v",
    "sha256": "FB4316E4F2037A835BC87D27D522F302C745D982914664DE1C272113B898526D",
    "bytes": 4684,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/raw8_display_enhance_golden.v",
    "sha256": "584B2D0EED363E4ADCF0F94E29F5EB4B006F6AAE1DA047C2C8EC69E87D37D9E3",
    "bytes": 2587,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/compile.log",
    "sha256": "ABF9D371585586113EFA80B0CBEAAF0A6CCBAB78CA59F5AFFA05F865AF8F7B67",
    "bytes": 427,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/result.json",
    "sha256": "1AE53147DB510C21FBEC84D3F9CACC79645649753A4EC2014D58F2FE3FFEEB36",
    "bytes": 348,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/markers_baseline_20261006/geometry/geometry_gray_sampler.v",
    "sha256": "79FD61F71DC2127069219E00BB9E96FAE9E897B4BE6134C3E87FFA9380C83EE9",
    "bytes": 4670,
    "kind": "input"
  },
  {
    "path": "fpga/build/markers_baseline_20261006/raw8_dual/raw8_display_enhance.v",
    "sha256": "43599B4193E1CAA046F82ECDFB34E6409EBAB10EF293273C0F61AD4D1BAD0AF2",
    "bytes": 2580,
    "kind": "input"
  },
  {
    "path": "fpga/rtl/geometry/geometry_window_sampler.v",
    "sha256": "AB2F630FD81A27A9081239ACD70893CD758310293F6A827EDE6AEA2149B142A2",
    "bytes": 2763,
    "kind": "input"
  },
  {
    "path": "fpga/rtl/geometry/geometry_gray_stream.v",
    "sha256": "FDE15A60C3DEFB38979AE367CE7C593C32CCCCD38DC4F9EFB2FACCFB27F8534E",
    "bytes": 3662,
    "kind": "input"
  },
  {
    "path": "fpga/rtl/raw8_dual/raw8_display_enhance.v",
    "sha256": "43599B4193E1CAA046F82ECDFB34E6409EBAB10EF293273C0F61AD4D1BAD0AF2",
    "bytes": 2580,
    "kind": "input"
  },
  {
    "path": "fpga/sim/tb_geometry_window.sv",
    "sha256": "49CAB74AB199B8B37011803826DD12E0D336A008162917FDD7098D4CED1BF5DD",
    "bytes": 16392,
    "kind": "input"
  },
  {
    "path": "fpga/scripts/sim_geometry_window.ps1",
    "sha256": "B986864494DFF6D007570721E42E66977D72DEB1E3605BD92EDBD76AAC180E0A",
    "bytes": 3831,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride32_cache64.log",
    "sha256": "695075F57691E488BF4AC6F36AF06F285B36FF94605936ADC9AAF6CC41D5C69C",
    "bytes": 1070,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride32_cache128.log",
    "sha256": "EEC4C67DD93C3FB9C6EDEF94750D2C906BD43A1234A21982C061AD5C0F371E15",
    "bytes": 1072,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride32_cache256.log",
    "sha256": "A05E6AD0A9CE33F9D4F16C69FADAA795923860100757143C887A70ED446DDDA7",
    "bytes": 1072,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride32_cache512.log",
    "sha256": "0ECFC8E4B942A8345BAB8E89784796AAD942582CA49A3177F5DBA74DD7F43147",
    "bytes": 1072,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride32_cache1024.log",
    "sha256": "18428CBDC71CDFB5AEEE927F39EB2C23442D54568A923890F4DA8D4D8E2762B5",
    "bytes": 1074,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride128_cache64.log",
    "sha256": "64E2A258FA706BBAC8875C709FCED25784DEFEEC713A33AE0B45D3802BA5D6AE",
    "bytes": 1072,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride128_cache128.log",
    "sha256": "8B51F2A8CF28D790A39695B700C16B5BEA4888F1A54BC304B91B7313D51A1B17",
    "bytes": 1074,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride128_cache256.log",
    "sha256": "98AA932E80C52A2C320172FE11AE3977C062A8BFBAE3AB03E33C892E4165A4AC",
    "bytes": 1074,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride128_cache512.log",
    "sha256": "0E9C06728B7B18E5F37D8A8DE281C47BCEB40774035FE8EB58FD1AE2E149A125",
    "bytes": 1074,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride128_cache1024.log",
    "sha256": "1F588D30EE99A1B386ADE2E63240E01044F0947F6A9B65431A0CD2341CCA2FAC",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride1536_cache64.log",
    "sha256": "6267A8664483F028E1A8CC9FBC802A8E989E5E215501D1EB8D21C2D5165EBFED",
    "bytes": 1074,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride1536_cache128.log",
    "sha256": "FC21136F0150A407320A1B3EDA3FA161C4B11EEF0897344DDDDFC6E08D75D23C",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride1536_cache256.log",
    "sha256": "4FF042E0C3DC279B73D0792B697AD7AAA0222A96DECDE0E954A0D799B0B460F0",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride1536_cache512.log",
    "sha256": "FCDF9D71D099F75181501A8C6D3FBA0C1D9C2872AD21498CF11039162F9F84C5",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride1536_cache1024.log",
    "sha256": "CA5F01910C588283023178AF1BF5FEB09332DCC323D3570B5D4CC1A18FADAB38",
    "bytes": 1078,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride2048_cache64.log",
    "sha256": "7ACAFAEB6C161011608B8FFDA377AB10C267FF741B0EA9EDE42246571CCDF0E2",
    "bytes": 1074,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride2048_cache128.log",
    "sha256": "E9E550FC7969D9CB0747FA6FFD0CD060DECE19964F5324FD27214A3D80CB659C",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride2048_cache256.log",
    "sha256": "B6D0F4C89F9BE332BA474F86C468EF626E88FF2F2CD4AFC269A89A24796AEF41",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride2048_cache512.log",
    "sha256": "70F847FBF9905B5617F0C778BAD2312B90083561848B5C5FB41D07EAD6315021",
    "bytes": 1076,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/cycle_miter_20261007_131440_971/cycle_stride2048_cache1024.log",
    "sha256": "4F974D88CBACBE54CA0418A404B691B70299453F742DC2D6A5A048CF0F3266D0",
    "bytes": 1078,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_32x8_stride32_cache64_pixels4096.log",
    "sha256": "BCF8FA956867567A32AACFFA40FBCDB66B709BA9D155CDF0B64525AA98B50693",
    "bytes": 2705,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_32x8_stride2048_cache64_pixels4096.log",
    "sha256": "E47AA6FCB26AAB7620350DC5AF40918E2839BD7A4201FF23A5A6665D6A4FD063",
    "bytes": 2730,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_70x19_stride128_cache64_pixels4096.log",
    "sha256": "48A0DCD1F82F68B646C257DF5E58B3A843271209560F04098C087BB75F232D8F",
    "bytes": 2753,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_1920x1080_stride2048_cache64_pixels4096.log",
    "sha256": "C14437A7C017D802C8EDB9004758B86292C1C3B95DEF525875E0203914A0DEAB",
    "bytes": 2804,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_1920x1080_stride2048_cache64_pixels30720.log",
    "sha256": "7408304C7D709F35B2FB62F931EEC2F4ED4FCE7A522B314B16A88FFC8793C54A",
    "bytes": 1814,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_32x8_stride32_cache256_pixels4096.log",
    "sha256": "5D19AEFA84B49FD96CC9D11C655695BDE69B5851B0E6B5B2AAE075AA9B6CFB6C",
    "bytes": 2728,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_32x8_stride2048_cache256_pixels4096.log",
    "sha256": "62FBDDD02473DDD84D681D2D87EFB9105E8F223DCF39959E5DEACAE593440C26",
    "bytes": 2784,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_70x19_stride128_cache256_pixels4096.log",
    "sha256": "CEDC39BFC41B4810E9709283F39D29326E73FF2692A74BD23088957653CB05C9",
    "bytes": 2748,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_1920x1080_stride2048_cache256_pixels4096.log",
    "sha256": "EDEAE83CC470B0E6D3E17A4C993F5C103FDFCB4A0875AC8C7EA79B0265FAE99C",
    "bytes": 2821,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_1920x1080_stride2048_cache256_pixels30720.log",
    "sha256": "88137B694070C88AC60184950532943887C199FA257E44BE0CD008612CBE4697",
    "bytes": 1821,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_32x8_stride32_cache1024_pixels4096.log",
    "sha256": "E1463474CABC02C2AC9A0CF95B3DD0830C0A41AD297C0DBD9BFF20A15F1409DD",
    "bytes": 2750,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_32x8_stride2048_cache1024_pixels4096.log",
    "sha256": "C8088B7E46BB818AF610AB9D52C80A5DF968011227B0246E56A218AF049328AB",
    "bytes": 2757,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_70x19_stride128_cache1024_pixels4096.log",
    "sha256": "19B82B88BFB7C1DA45D1089C0DBDA991ED980B91263ECC2FA812F42DDE3B91C8",
    "bytes": 2760,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_1920x1080_stride2048_cache1024_pixels4096.log",
    "sha256": "553043CE71BDA44F55182839B4302866762C484CEC64C817ABED3BE9EA075B7B",
    "bytes": 2831,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/existing_window_regression/window_1920x1080_stride2048_cache1024_pixels30720.log",
    "sha256": "D9D6B57B02432C4509C17476F52E19DE47B953F82AE3F4369AF1BD12A785A943",
    "bytes": 1821,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_golden/impl.tcl",
    "sha256": "3C58323C26F6A35CA30E11E81D8B73ECD80187708110B01C487D46C7EE90109A",
    "bytes": 581,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_golden/result.json",
    "sha256": "79D0D2FF3D0C20490E3A45132789D93A64631FE258364D267107C1A3E9A6C895",
    "bytes": 1206,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_golden/native.log",
    "sha256": "B9B0912C9220CC05AD60B0D24AFCDD561355ADD389DEEAC7EEAF9DED0E4ED10A",
    "bytes": 127592,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_golden/synthesize/geometry_marker_overlay.snr",
    "sha256": "AFE21D9DE227F5E697B9E5D855EFB3CD5222E1C26283244CF448FC8FCB0671A2",
    "bytes": 109943,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_golden/synthesize/geometry_marker_overlay_syn.vm",
    "sha256": "FEE34A1961E67F3F61D9B1AB36CB2CC2AEC5698F4EC55D30FF8E36E2FEEA4F25",
    "bytes": 3729354,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_candidate/impl.tcl",
    "sha256": "C9E665B381D173EABC4853AD2D01E38332B2E9E22518FD2A9007E9C3D7033F3E",
    "bytes": 584,
    "kind": "input"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_candidate/result.json",
    "sha256": "5385344786C43D7C21D97C8B89034CC43702C6AA6D2AD78B94A445E26137CCB1",
    "bytes": 1207,
    "kind": "metadata"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_candidate/native.log",
    "sha256": "13100A94E19D064627895DAA83A134BE3E0A3EEC7E2808741633A6542969F59B",
    "bytes": 122567,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_candidate/synthesize/geometry_marker_overlay.snr",
    "sha256": "265B93464B701A68E8E509D2B94C852CA46DBC5AD9E61B0465643C73385271AC",
    "bytes": 90281,
    "kind": "log"
  },
  {
    "path": "fpga/build/overlay_area_20261007_131138/synth_candidate/synthesize/geometry_marker_overlay_syn.vm",
    "sha256": "0E8201854D1B5296A25BEA13854569F07A143826C0FB7356284C028BC9003A01",
    "bytes": 2526838,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/ram_256.v",
    "sha256": "3B43DE3A5780EEC6AC73A1DC0FE6CB98EED98BADB5A6556B324EEAA1BD0EEABA",
    "bytes": 1196,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_256/impl.tcl",
    "sha256": "302C0A5E3F858C816DA8F37EF198CC37F036492E9006F1AA120DB506A59F4725",
    "bytes": 472,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_256/native.log",
    "sha256": "26784B60B41ACA9B978D341F919F89DD17EDF1CC419FBC658C120E36E9CB2A7C",
    "bytes": 90332,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_256/compile/run.log",
    "sha256": "7553A840003F7B1CD1E7B7AA56C6863B73CEFBEB3CDE4443C4B3B2BE46AA32DC",
    "bytes": 3997,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_256/synthesize/geometry_cache_packed_ram_probe.snr",
    "sha256": "D0FCF793A838135672EDFEBD1B4E8B59CA5B6F28E7128F30E605A3408D780ED1",
    "bytes": 26906,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_256/synthesize/geometry_cache_packed_ram_probe_syn.vm",
    "sha256": "FA81FF36720A1112F6A0EF882B9F3E1C081FA05147FCE5D0DE77C41824A2A85C",
    "bytes": 592132,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_256/synthesize/apm_drm_lutram_utilization.log",
    "sha256": "885AAFFC38581A4371EDCDCF51401F6D3A8BC0A2C09933EB0C07196AF020E3A5",
    "bytes": 2187,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/ram_269.v",
    "sha256": "21CE5648723A18B5C272B305F5BEE2C0D53BBD437A8DF8BBA8B953967D1B2FF4",
    "bytes": 1196,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_269/impl.tcl",
    "sha256": "D067383F90CDE6A848A0569D3B67E8EF5DC13CF479D3D6BD43E9F839D82124A3",
    "bytes": 472,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_269/native.log",
    "sha256": "21ED3E2546371C53E42FBD97E7764B4DD8B1242C08187332CB61899839B6DFE7",
    "bytes": 94153,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_269/compile/run.log",
    "sha256": "615777D20C3A3FF5ADBEFAF66BECC2E849573D3F58DB9A6FD9D617B428BB1B3B",
    "bytes": 3996,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_269/synthesize/geometry_cache_packed_ram_probe.snr",
    "sha256": "1D91600759FC265FD1F2CDF21BE4B8433A8BE2839E5E82E30419F2A7296F67EA",
    "bytes": 26906,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_269/synthesize/geometry_cache_packed_ram_probe_syn.vm",
    "sha256": "483DC15AE944C9230BE01EF2AD625F91E5E8C81267CA91375D2CE263931498E5",
    "bytes": 603649,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_269/synthesize/apm_drm_lutram_utilization.log",
    "sha256": "18AE5DBDC537C1CBF70626CEB67EEDB54BABDE6F76930284A9E42B356AB95499",
    "bytes": 2232,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/ram_279.v",
    "sha256": "65123BF387F71EC8383C502A3CA954DCC9B3A6AFA12D8BDA4AFBB7D6B0CA6E2C",
    "bytes": 1196,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_279/impl.tcl",
    "sha256": "943BF9BD69E9F1620DEB98306CA2BEC2E02D6A349511820BE62B9412199C16F0",
    "bytes": 472,
    "kind": "input"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_279/native.log",
    "sha256": "F14A15A057DA136EF9894A141B36F96F9781E648B43589F995A94FB90DD4C6C0",
    "bytes": 97095,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_279/compile/run.log",
    "sha256": "1309A504A9814A4497E8FEA6CC3B2610AF1A70EB1E93FBBF071B36379FDB7C4B",
    "bytes": 3998,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_279/synthesize/geometry_cache_packed_ram_probe.snr",
    "sha256": "2465138DE486D253C4691A2A669FAB05884B36E62EEFD653B1DACABB9C05B09F",
    "bytes": 26906,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_279/synthesize/geometry_cache_packed_ram_probe_syn.vm",
    "sha256": "D0150CA62F211774F532692657B21F702631D76F3B34F0B7F48D01A75C1DE848",
    "bytes": 610703,
    "kind": "log"
  },
  {
    "path": "fpga/build/cache_tag_packed_20261007_131154_460/main_ram_probe/width_279/synthesize/apm_drm_lutram_utilization.log",
    "sha256": "35DB6DB5E1D4FC77404F170F9EB39E7436DE31F59FA8989AF18707593BBB099B",
    "bytes": 2232,
    "kind": "log"
  }
]
'@|ConvertFrom-Json
$expectedMatrix=@'
{
  "writer": {
    "split_bits": 256,
    "coincident_bits": 256,
    "highest_bit": 255,
    "done_delay_clocks": 1,
    "reset_cases": 3
  },
  "overlay": {
    "sizes": 64,
    "rounding_vectors": 262144,
    "full1080_frames": 1,
    "random_cycles": 20000,
    "delay_clocks": 2,
    "original_bench_frames": 242
  },
  "cache_cycle": [
    {
      "stride": 32,
      "cache_words": 64
    },
    {
      "stride": 32,
      "cache_words": 128
    },
    {
      "stride": 32,
      "cache_words": 256
    },
    {
      "stride": 32,
      "cache_words": 512
    },
    {
      "stride": 32,
      "cache_words": 1024
    },
    {
      "stride": 128,
      "cache_words": 64
    },
    {
      "stride": 128,
      "cache_words": 128
    },
    {
      "stride": 128,
      "cache_words": 256
    },
    {
      "stride": 128,
      "cache_words": 512
    },
    {
      "stride": 128,
      "cache_words": 1024
    },
    {
      "stride": 1536,
      "cache_words": 64
    },
    {
      "stride": 1536,
      "cache_words": 128
    },
    {
      "stride": 1536,
      "cache_words": 256
    },
    {
      "stride": 1536,
      "cache_words": 512
    },
    {
      "stride": 1536,
      "cache_words": 1024
    },
    {
      "stride": 2048,
      "cache_words": 64
    },
    {
      "stride": 2048,
      "cache_words": 128
    },
    {
      "stride": 2048,
      "cache_words": 256
    },
    {
      "stride": 2048,
      "cache_words": 512
    },
    {
      "stride": 2048,
      "cache_words": 1024
    }
  ],
  "cache_scalar": [
    {
      "width": 32,
      "height": 8,
      "stride": 32,
      "cache_words": 64,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 32,
      "height": 8,
      "stride": 2048,
      "cache_words": 64,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 70,
      "height": 19,
      "stride": 128,
      "cache_words": 64,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 1920,
      "height": 1080,
      "stride": 2048,
      "cache_words": 64,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 1920,
      "height": 1080,
      "stride": 2048,
      "cache_words": 64,
      "pixels": 30720,
      "seed": 20261006
    },
    {
      "width": 32,
      "height": 8,
      "stride": 32,
      "cache_words": 256,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 32,
      "height": 8,
      "stride": 2048,
      "cache_words": 256,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 70,
      "height": 19,
      "stride": 128,
      "cache_words": 256,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 1920,
      "height": 1080,
      "stride": 2048,
      "cache_words": 256,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 1920,
      "height": 1080,
      "stride": 2048,
      "cache_words": 256,
      "pixels": 30720,
      "seed": 20261006
    },
    {
      "width": 32,
      "height": 8,
      "stride": 32,
      "cache_words": 1024,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 32,
      "height": 8,
      "stride": 2048,
      "cache_words": 1024,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 70,
      "height": 19,
      "stride": 128,
      "cache_words": 1024,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 1920,
      "height": 1080,
      "stride": 2048,
      "cache_words": 1024,
      "pixels": 4096,
      "seed": 20261006
    },
    {
      "width": 1920,
      "height": 1080,
      "stride": 2048,
      "cache_words": 1024,
      "pixels": 30720,
      "seed": 20261006
    }
  ]
}
'@|ConvertFrom-Json
$manifestPath=Join-Path $evidence 'resource_manifest.json'
Require (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'Missing resource_manifest.json'
$manifestSha=Digest $manifestPath
$m=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
Keys $m @('schema_version','passed','files','matrix') 'manifest'
Require ($m.schema_version -ceq 'geometry-resource-manifest/v1') 'Wrong manifest schema version'
TrueBoolean $m.passed 'manifest.passed'
Require ($m.files -is [array] -and $m.files.Count -eq $expectedFiles.Count -and $m.files.Count -gt 0) 'Incomplete finite file inventory'
$byPath=@{}
foreach($f in $m.files){
 Keys $f @('path','sha256','bytes','kind') 'file'
 Require ($f.path -is [string] -and $f.sha256 -is [string] -and $f.sha256 -cmatch '^[0-9A-F]{64}$') 'Invalid file identity'
 Integer $f.bytes 'file.bytes'
 Require ($f.kind -is [string] -and $f.kind -cin @('input','log','metadata')) 'Invalid file.kind'
 Require (-not $byPath.ContainsKey($f.path)) "Duplicate file: $($f.path)"
 $byPath[$f.path]=$f
}
function Snapshot{
 $list=@()
 foreach($x in $expectedFiles){
  Require ($byPath.ContainsKey($x.path)) "Missing finite input/log: $($x.path)"
  $f=$byPath[$x.path]
  Require ($f.path -ceq $x.path -and $f.sha256 -ceq $x.sha256 -and $f.bytes -eq $x.bytes -and $f.kind -ceq $x.kind) "Freeze identity drift: $($x.path)"
  $p=Full $f.path
  Require ((Get-Item -LiteralPath $p).Length -eq $f.bytes -and (Digest $p) -ceq $f.sha256) "Stale source/log: $($f.path)"
  $list += [pscustomobject][ordered]@{path=$f.path;sha256=$f.sha256;bytes=$f.bytes;kind=$f.kind}
 }
 return $list
}
$before=@(Snapshot)
Keys $m.matrix @('writer','overlay','cache_cycle','cache_scalar') 'matrix'
foreach($name in @('writer','overlay')){
 $a=$m.matrix.$name;$b=$expectedMatrix.$name
 Keys $a @($b.PSObject.Properties.Name) $name
 foreach($prop in $b.PSObject.Properties.Name){Integer $a.$prop "$name.$prop";Require ($a.$prop -eq $b.$prop) "$name coverage mismatch: $prop"}
}
foreach($name in @('cache_cycle','cache_scalar')){
 $items=$m.matrix.$name;$want=$expectedMatrix.$name
 Require ($items -is [array] -and $items.Count -eq $want.Count) "$name incomplete matrix"
 $seen=@{}
 foreach($item in $items){
  Keys $item @($want[0].PSObject.Properties.Name) $name
  $id=(@($want[0].PSObject.Properties.Name|ForEach-Object {Integer $item.$_ "$name.$_";[string]$item.$_})-join ':')
  Require (-not $seen.ContainsKey($id)) "$name duplicate case";$seen[$id]=$true
 }
 foreach($item in $want){
  $id=(@($want[0].PSObject.Properties.Name|ForEach-Object {[string]$item.$_})-join ':')
  Require ($seen.ContainsKey($id)) "$name missing case: $id"
 }
}
$w='fpga/build/writer_fence_pipeline_20261007_125622_690'
$o='fpga/build/overlay_area_20261007_131138'
$c='fpga/build/cache_tag_packed_20261007_131154_460'
$os="$o/sim_verified_20261007_132421_601";$cc="$c/cycle_miter_20261007_131440_971";$cs="$c/existing_window_regression"
# Golden fixtures are exact full-text module/type renames, not new baselines.
Require ((Read "$w/golden.v").Replace('geometry_result_stream_writer','geometry_result_stream_writer_golden').Replace('geometry_write_packet_fifo','geometry_write_packet_fifo_golden') -ceq (Read "$w/golden_renamed.v")) 'Writer golden rename drift'
Require ((Read "$o/golden.v").Replace('module geometry_marker_overlay #','module geometry_marker_overlay_golden #') -ceq (Read "$o/golden_fixture.v")) 'Overlay golden rename drift'
Require ((Read "$c/geometry_window_cache.compact_golden.v").Replace('module geometry_window_cache #','module geometry_window_cache_golden #') -ceq (Read "$cc/geometry_window_cache_golden.v")) 'Cache golden rename drift'
Require ((Read "$c/geometry_window_cache_packed.v").Replace('module geometry_window_cache_packed #','module geometry_window_cache #') -ceq (Read "$c/geometry_window_cache.v")) 'Cache candidate module alias drift'
Require ((Read "$w/candidate_frozen.v") -ceq (Read 'fpga/rtl/geometry/geometry_result_stream_writer.v')) 'Writer merge binding mismatch'
Require ((Read "$o/candidate.v") -ceq (Read 'fpga/rtl/geometry/geometry_marker_overlay.v')) 'Overlay merge binding mismatch'
# Only TWO explicit comment substitutions; preserve all synthesis attributes,
# code, whitespace and remaining comments. This is not generic comment stripping.
$cache=Read "$c/geometry_window_cache.v"
$old=@('// Purpose: isolated packed-tag experiment; not a board source. Frozen compact','  // standalone array. The physical packing and port mode require a probe.')
$new=@('// Purpose: packed-tag cache for the board geometry sampler. Derived compact','  // standalone array. Native 256/269/279-bit probes each infer 8 TRUE_DUAL_PORT')
for($i=0;$i -lt 2;$i++){Require (([regex]::Matches($cache,[regex]::Escape($old[$i]))).Count -eq 1) 'Nonunique allowed cache comment';$cache=$cache.Replace($old[$i],$new[$i])}
Require ($cache -ceq (Read 'fpga/rtl/geometry/geometry_window_cache.v')) 'Cache merge differs beyond two authorized comments'
function Modules([string]$Path,[string[]]$Names){
 $log=Read $Path;Require ($log -notmatch '\*\* (Error|Fatal)') "Compilation failure: $Path"
 $actual=@([regex]::Matches($log,'(?m)^-- Compiling module (\w+)')|ForEach-Object {$_.Groups[1].Value}|Sort-Object)
 Require (($actual-join '|') -ceq (($Names|Sort-Object)-join '|')) "Actual compiled units mismatch: $Path"
}
function Pass([string]$Path,[string]$Pattern){
 $log=Read $Path
 Require ($log -notmatch '\*\* (Error|Fatal)|(?m)^#.*\b[A-Z_]+_FAIL\b') "Failure in log: $Path"
 Require (([regex]::Matches($log,$Pattern)).Count -eq 1) "Missing/duplicate exact PASS: $Path"
}
# Match historical metadata suffix, never dereference its obsolete baseline.
function SourceRecord([string]$Metadata,[string]$Relative){
 $rows=Json $Metadata;$want=$byPath[$Relative].sha256;$suffix=$Relative.Replace('/','\')
 $hits=@($rows|Where-Object {$_.path.Replace('/','\').EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)})
 Require ($hits.Count -eq 1 -and $hits[0].sha256 -ceq $want) "Compiled source manifest mismatch: $Relative"
}
Modules "$w/miter_final/compile.log" @('geometry_result_stream_writer','geometry_write_packet_fifo','geometry_result_stream_writer_golden','geometry_write_packet_fifo_golden','tb_writer_fence_miter')
Pass "$w/miter_final/simulation.log" 'WRITER_FENCE_MITER_PASS frames=528 completed=525 cycles=165085 checks=165085 errors_split=256 errors_coincident=256 reset_cases=3 golden_done=526 candidate_done=525 AW_stalls=771 W_stalls=15284 AW_W_coincident=1365 AW_W_split=3387'
$we=Json "$w/writer_miter_evidence.json"
Require ($we.status -ceq 'PASS' -and $we.tool -match '\+acc') 'Writer status/+acc missing'
TrueBoolean $we.single_bit_errors.includes_bit_255 'writer bit255'
FalseBoolean $we.formal_modified_by_this_task 'writer formal modification'
foreach($file in @('candidate_frozen.v','golden_renamed.v','tb_writer_fence_miter.sv')){Require ((Read "$w/miter_final/compile.log").Contains($file)) 'Writer actual compile source missing'}
Modules "$os/compile.log" @('geometry_marker_catalog','geometry_marker_overlay_golden','geometry_marker_overlay','tb_overlay_miter','tb_geometry_marker_overlay')
foreach($file in @('candidate.v','golden.v','golden_fixture.v','geometry_marker_catalog.v','marker_golden.hex','tb_overlay_miter.sv','tb_geometry_marker_overlay.sv')){SourceRecord "$o/proof_sources.json" "$o/$file"}
SourceRecord "$os/run_sources.json" "$o/run_sim_fresh.ps1";SourceRecord "$os/run_sources.json" "$o/proof_sources.json"
Require ((Read "$o/run_sim_fresh.ps1").Contains("'geometry_marker_catalog.v','golden_fixture.v','candidate.v','tb_overlay_miter.sv','tb_geometry_marker_overlay.sv'")) 'Overlay compile command mismatch'
Require ((Read "$o/marker_golden.hex") -ceq (Read "$os/marker_golden.hex")) 'Overlay catalog fixture mismatch'
Pass "$os/tb_overlay_miter.log" 'OVERLAY_MITER_PASS cycles=2860061 sizes=64 rounding_vectors=262144 random_cycles=20000 full1080_frames=1'
Pass "$os/tb_geometry_marker_overlay.log" 'GEOMETRY_MARKER_OVERLAY_PASS frames=242 checked_clocks=768350'
$or=Json "$os/result.json";TrueBoolean $or.passed 'overlay.passed';TrueBoolean $or.sources_unchanged 'overlay.sources_unchanged';FalseBoolean $or.formal_proof 'overlay formal proof'
Modules "$cc/compile.log" @('geometry_window_cache_golden','geometry_window_cache_packed','tb_cache_tag_cycle')
foreach($file in @('geometry_window_cache.compact_golden.v','geometry_window_cache_packed.v','tb_cache_packed_cycle.sv','run_cycle_miter.ps1')){SourceRecord "$cc/sources.json" "$c/$file"}
$cr=Json "$cc/result.json";TrueBoolean $cr.passed 'cache.cycle.passed'
Require ($cr.cases -is [array] -and $cr.cases.Count -eq 20) 'Cache actual result case count'
foreach($case in $expectedMatrix.cache_cycle){
 $stride=$case.stride;$words=$case.cache_words;$name="cycle_stride$($stride)_cache$($words).log"
 $hits=@($cr.cases|Where-Object {$_.stride -eq $stride -and $_.cache_words -eq $words -and $_.log -ceq $name})
 Require ($hits.Count -eq 1) 'Cache actual matrix missing/duplicate';TrueBoolean $hits[0].passed 'cache case.passed'
 # Compact-tag cases intentionally reject three wrong-slot responses; fallback
 # cases reject zero. Compare every metric with the frozen per-case handoff.
 $metrics=@((Json "$c/handoff.json").cycle_metrics|Where-Object {$_.log -ceq $name})
 Require ($metrics.Count -eq 1) 'Missing frozen case metrics'
 $metric=$metrics[0]
 $fields=@('stride','cache_words','tag_bits','cycles','accepted','emitted','reads','promotions','replays','stalls','wrong_slot_rejects','tag_commits','grant_replies','fault_cases')
 $line='PACKED_CYCLE_EQUIVALENCE_PASS '+(@($fields|ForEach-Object {"$_=$($metric.$_)"})-join ' ')
 Pass "$cc/$name" ([regex]::Escape($line))
}
Modules "$cs/compile.log" @('geometry_gray_sampler_golden','raw8_display_enhance_golden','geometry_window_sampler','geometry_window_cache','geometry_gray_stream','raw8_display_enhance','tb_geometry_window')
foreach($p in @("$c/geometry_window_cache.v",'fpga/build/markers_baseline_20261006/geometry/geometry_gray_sampler.v','fpga/build/markers_baseline_20261006/raw8_dual/raw8_display_enhance.v','fpga/rtl/geometry/geometry_window_sampler.v','fpga/rtl/geometry/geometry_gray_stream.v','fpga/rtl/raw8_dual/raw8_display_enhance.v','fpga/sim/tb_geometry_window.sv','fpga/scripts/sim_geometry_window.ps1')){SourceRecord "$cs/sources.json" $p}
$sr=Json "$cs/result.json";TrueBoolean $sr.passed 'cache.scalar.passed'
foreach($case in $expectedMatrix.cache_scalar){
 $name="window_$($case.width)x$($case.height)_stride$($case.stride)_cache$($case.cache_words)_pixels$($case.pixels).log"
 Pass "$cs/$name" "WINDOW_EQUIVALENCE_PASS width=$($case.width) height=$($case.height) stride=$($case.stride) cache_words=$($case.cache_words) pixels=$($case.pixels) seed=20261006"
}
TrueBoolean (Json "$c/handoff.json").passed 'cache.handoff.passed'
# Native evidence is isolated-top/probe only, NOT full-board fit/LUT/timing.
$target='set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676'
foreach($side in @('golden','candidate')){
 $p="$o/synth_$side";$t=Read "$p/impl.tcl";$report=Read "$p/synthesize/geometry_marker_overlay.snr"
 Require ($t.Contains($target) -and $t.Contains('geometry_marker_overlay') -and $t.Contains('selected_syn_tool_opt 2')) 'Area target/tool mismatch'
 Require ($report -match 'version 2022\.2-SP6\.4 <build 146967>') 'Area compiler version mismatch'
 $lut=6133;if($side -eq 'candidate'){$lut=3877}
 Require ($report -match "Total LUTs: $lut of 66600" -and $report -match 'Total Registers: 118 of 133200') 'Native LUT/register mismatch'
 $nr=Json "$p/result.json";TrueBoolean $nr.native_synthesis 'area.native_synthesis'
 Require ($nr.lut -eq $lut -and $nr.ff -eq 118 -and $nr.report_sha256 -ceq $byPath["$p/synthesize/geometry_marker_overlay.snr"].sha256 -and $nr.netlist_sha256 -ceq $byPath["$p/synthesize/geometry_marker_overlay_syn.vm"].sha256) 'Native result/hash mismatch'
 FalseBoolean $nr.pnr 'area.pnr';FalseBoolean $nr.timing_verified 'area.timing'
 $source='golden.v';if($side -eq 'candidate'){$source='candidate.v'}
 Require ($t.Replace('\','/').Contains("$o/$source") -and $t.Replace('\','/').Contains("$o/geometry_marker_catalog.v")) 'Native actual source binding mismatch'
}
foreach($width in @(256,269,279)){
 $p="$c/main_ram_probe/width_$width";$t=Read "$p/impl.tcl";$report=Read "$p/synthesize/geometry_cache_packed_ram_probe.snr";$vm=Read "$p/synthesize/geometry_cache_packed_ram_probe_syn.vm"
 Require ((Read "$c/main_ram_probe/ram_$width.v") -match "parameter WORD_BITS=$width\)") 'Probe actual width mismatch'
 Require ($t.Contains($target) -and $t.Replace('\','/').Contains("$c/main_ram_probe/ram_$width.v") -and $t.Contains('selected_syn_tool_opt 2')) 'Probe target/source mismatch'
 Require ($report -match 'version 2022\.2-SP6\.4 <build 146967>' -and $report -match 'GTP_DRM36K_E1\s+8 uses' -and $report -match 'Total DRM = 8\.0 of 155') 'Probe DRM count/version mismatch'
 $blocks=@([regex]::Matches($vm,'(?s)GTP_DRM36K_E1\s*/\*.*?\*/\s*#\((.*?)\)\s*\w+\s*\('))
 Require ($blocks.Count -eq 8) 'Probe must contain exactly 8 DRM instances'
 foreach($block in $blocks){Require ($block.Groups[1].Value -match '\.RAM_MODE\("TRUE_DUAL_PORT"\)') 'Probe has a non TRUE_DUAL_PORT DRM'}
}
$after=@(Snapshot)
Require ((Digest $manifestPath) -ceq $manifestSha) 'Manifest changed during validation'
Require ((Digest $timingChecker) -ceq $timingCheckerSha) 'Parallel-valid checker changed during validation'
$cacheAfter=& $timingChecker -WorkspaceRoot $root -EvidenceDirectory $CacheTimingEquivalence -CheckPublishedEvidence
Require (($cacheProof|ConvertTo-Json -Depth 30 -Compress) -ceq ($cacheAfter|ConvertTo-Json -Depth 30 -Compress)) 'Parallel-valid evidence changed during resource validation'
# Consumer contract: typed bool passed, version and complete before/after arrays.
$result=[ordered]@{
 schema_version='geometry-resource-evidence/v2';passed=$true;sources_unchanged=$true
 historical_bindings=$historicalBindings;historical_cache_sha256='0F3CB37128B5544FDB764BD071AD969256F62B900391566507A962BB1324C385'
 cache_timing_equivalence=$cacheAfter
 manifest_sha256=$manifestSha;validator_sha256=(Digest $PSCommandPath)
 formal_sources=@($after|Where-Object {$_.path -cin @('fpga/rtl/geometry/geometry_result_stream_writer.v','fpga/rtl/geometry/geometry_marker_overlay.v')})+@($cacheAfter.current_source)
 inputs_before=@($before|Where-Object {$_.kind -ne 'log'});inputs_after=@($after|Where-Object {$_.kind -ne 'log'})
 logs_before=@($before|Where-Object {$_.kind -eq 'log'});logs_after=@($after|Where-Object {$_.kind -eq 'log'})
 matrix=$expectedMatrix
 resources=[ordered]@{scope='isolated_top_and_ram_probes';device='PG2L100H';package='FBG676';speedgrade='-6';tool='PDS 2022.2-SP6.4 build 146967';overlay_golden_lut=6133;overlay_candidate_lut=3877;overlay_ff=118;probe_widths=@(256,269,279);drm_per_probe=8;ram_mode='TRUE_DUAL_PORT';fullboard_lut=$null}
 formal_proof=$false;timing_verified=$false;hardware_verified=$false
 limitations=@('Bounded simulation, not unbounded sequential formal equivalence.','Writer next start after both publications; early-start in publication gap, X/Z and FIFO-full not covered.','Historical compact/packed proof and 15 scalar cases terminate at production 0F; 30720 pixels is trace only, not full frame.','Separate 40-case 0F-to-69422B proof compares raw validity and all common state at 125 MHz; it does not measure physical timing or LUTs.','Overlay full1080 and 242 original-bench color/number frames are covered; LUT counts are isolated overlay top, NOT full board.','RAM probes prove template inference counts/modes, not full cache placement/routing/timing/hardware.')
}
# Purpose: exporter preflight/postflight require the on-disk publication itself
# to match this fresh read-only result, not merely a truthy passed property.
# Recursive closed-schema checks preserve bool/integer/string/array types.
function SameValue($Actual,$Wanted,[string]$Label){
 if($null -eq $Wanted){Require ($null -eq $Actual) "$Label must be null";return}
 if($Wanted -is [bool]){Require ($Actual -is [bool] -and $Actual -eq $Wanted) "$Label typed boolean mismatch";return}
 if($Wanted -is [string]){Require ($Actual -is [string] -and $Actual -ceq $Wanted) "$Label string mismatch";return}
 if($Wanted -is [int] -or $Wanted -is [long]){Require (($Actual -is [int] -or $Actual -is [long]) -and $Actual -eq $Wanted) "$Label integer mismatch";return}
 if($Wanted -is [array]){
  Require ($Actual -is [array] -and $Actual.Count -eq $Wanted.Count) "$Label array mismatch"
  for($i=0;$i -lt $Wanted.Count;$i++){SameValue $Actual[$i] $Wanted[$i] "$Label[$i]"};return
 }
 $names=@();if($Wanted -is [Collections.IDictionary]){$names=@($Wanted.Keys)}else{$names=@($Wanted.PSObject.Properties.Name)}
 Keys $Actual $names $Label
 foreach($name in $names){SameValue $Actual.$name $Wanted.$name "$Label.$name"}
}
if($CheckPublishedEvidence -or ($ValidateOnly -and (Test-Path -LiteralPath (Join-Path $evidence 'resource_evidence.json') -PathType Leaf))){
 Require $ValidateOnly 'CheckPublishedEvidence requires ValidateOnly'
 $publishedPath=Join-Path $evidence 'resource_evidence.json'
 Require (Test-Path -LiteralPath $publishedPath -PathType Leaf) 'Missing resource_evidence.json'
 $publishedSha=Digest $publishedPath
 $published=[IO.File]::ReadAllText($publishedPath)|ConvertFrom-Json
 SameValue $published $result 'resource_evidence'
 Require ((Digest $publishedPath) -ceq $publishedSha) 'Published evidence changed during validation'
}
if(-not $ValidateOnly){
 $out=Join-Path $evidence 'resource_evidence.json'
 $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($result|ConvertTo-Json -Depth 20))
 $stream=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}
[pscustomobject]$result

