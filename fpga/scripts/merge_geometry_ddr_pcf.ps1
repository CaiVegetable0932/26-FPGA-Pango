# Purpose: merge an explicitly reviewed DDR placement profile into a NEW mapped
# board PCF without replacing board pins, regions, or the four HDMI reset sites.
# This is a fail-closed text gate, not PCE legalization or timing signoff.
# Without NativeNetlist, the result is explicitly unverified/experimental and
# requires native fixed-leaf, name, type and site validation before acceptance.
# If supplied, NativeNetlist must be native Inst/name;gopType evidence for the map.
# gen_netlist rejects map ADFs in PDS 2022.2-SP6.4 (requires PNR); do not supply an
# old PNR netlist and claim it verifies a new map. MapAdf is provenance only: this
# script cannot prove an arbitrary netlist was generated from that DB.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MapPcf,
    [string]$NativeNetlist,
    [Parameter(Mandatory=$true)][string]$DeltaPcf,
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [string]$MapAdf,
    [ValidateSet('ten','critical37')][string]$Profile='ten'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Freeze the shared policy as an input before loading its constant allowlist.
$scopePath=Join-Path $PSScriptRoot 'geometry_ddr_scope.ps1'

# Hash the exact bytes which are inspected, then verify the source files again
# before publishing. Ordinal dictionaries preserve case-sensitive HDL names.
function Get-InputEvidence([string]$Path) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    if (!(Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Not a file: $resolved" }
    $bytes=[IO.File]::ReadAllBytes($resolved)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') }
    finally { $sha.Dispose() }
    [pscustomobject]@{path=$resolved;sha256=$hash;bytes=$bytes;length=$bytes.Length}
}
function Get-Utf8Text($InputEvidence) {
    $encoding=New-Object System.Text.UTF8Encoding($false,$true)
    $encoding.GetString($InputEvidence.bytes).TrimStart([char]0xFEFF)
}
function New-OrdinalMap { ,([Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)) }
function Get-ActiveLines([string]$Text) {
    @($Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and !$_.StartsWith('#') })
}

$base=Get-InputEvidence $MapPcf
$delta=Get-InputEvidence $DeltaPcf
$self=Get-InputEvidence $PSCommandPath
$scopeEvidence=Get-InputEvidence $scopePath
. $scopePath
$scope=Get-GeometryDdrScope -Profile $Profile
$inputs=@($base,$delta,$self,$scopeEvidence)
$native=$null
if ($NativeNetlist) { $native=Get-InputEvidence $NativeNetlist; $inputs+=$native }
if ($MapAdf) { $inputs+=Get-InputEvidence $MapAdf }
$baseText=Get-Utf8Text $base
$deltaText=Get-Utf8Text $delta
$baseLines=@(Get-ActiveLines $baseText)
$deltaLines=@(Get-ActiveLines $deltaText)
foreach ($line in @($baseLines)+@($deltaLines)) {
    if ($line -match '(?i)no_check') { throw 'Forbidden no_check in active PCF content.' }
}

# Exact pre-PNR scope/type comes from the hash-bound constant helper. critical37
# also binds sites; default ten retains its historical conservative policy.
$expected=New-OrdinalMap
foreach ($leaf in $scope.Values) { $expected.Add($leaf.name,$leaf.expected_type) }

# Only single-line native site declarations are accepted in the delta. Never
# evaluate Tcl from an input; reject extra switches, commands or substitutions.
$sitePattern='^def_inst_site\s+\{([^{};\r\n]+)\}\s+([A-Za-z][A-Za-z0-9_]*)(?:\s+([A-Za-z][A-Za-z0-9_]*))?$'
$baseSites=New-OrdinalMap
$baseGrids=New-OrdinalMap
foreach ($line in $baseLines) {
    if ($line -notmatch '^def_inst_site(?:\s|$)') { continue }
    if ($line -cnotmatch $sitePattern) { throw "Unsupported base site syntax: $line" }
    $name=$Matches[1]; $grid=$Matches[2]; $subsite=$Matches[3]
    if ($baseSites.ContainsKey($name)) { throw "Duplicate base name: $name" }
    $baseSites.Add($name,[pscustomobject]@{name=$name;grid=$grid;subsite=$subsite;line=$line})
    if (!$baseGrids.ContainsKey($grid)) { $baseGrids.Add($grid,[Collections.Generic.List[object]]::new()) }
    foreach ($previous in $baseGrids[$grid]) {
        if (!$previous.subsite -or !$subsite -or $previous.subsite -ceq $subsite) {
            throw "Conflicting base site: $grid $subsite"
        }
    }
    $baseGrids[$grid].Add($baseSites[$name])
}

# Require and preserve the four mapped HDMI reset site declarations, regardless
# of their reviewed location choice. Board bytes are copied verbatim below.
$resetNames=@(
    'u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv',
    'u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset/opit_0_inv',
    'u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset/opit_0_inv',
    'u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv'
)
foreach ($name in $resetNames) {
    if (!$baseSites.ContainsKey($name)) { throw "Missing HDMI reset site: $name" }
}
$portCount=@($baseLines | Where-Object { $_ -cmatch '^def_port\s' }).Count
if (!$portCount) { throw 'Base PCF has no board ports; a delta is not a complete board PCF.' }

$chosen=New-OrdinalMap
$chosenGrids=New-OrdinalMap
foreach ($line in $deltaLines) {
    if ($line -cnotmatch $sitePattern) { throw "Unsupported delta syntax: $line" }
    $name=$Matches[1]; $grid=$Matches[2]; $subsite=$Matches[3]
    if (!$expected.ContainsKey($name)) { throw "Out-of-scope delta leaf: $name" }
    if ($chosen.ContainsKey($name) -or $baseSites.ContainsKey($name) -or $baseSites.ContainsKey($name+'_perm')) {
        throw "Duplicate/conflicting leaf name: $name"
    }
    Assert-GeometryDdrSite $scope[$name] $grid $subsite $Profile
    # ten keeps whole-tile exclusion. The approved critical37 experiment may
    # share distinct subsite anchors, but never a whole-tile/exact-site conflict.
    if ($Profile -eq 'ten' -and ($baseGrids.ContainsKey($grid) -or $chosenGrids.ContainsKey($grid))) {
        throw "Occupied candidate grid/site: $grid $subsite"
    }
    foreach($gridMap in @($baseGrids,$chosenGrids)) {
        if($gridMap.ContainsKey($grid)) {
            foreach($previous in $gridMap[$grid]) {
                if(!$previous.subsite -or $previous.subsite -ceq $subsite){throw "Occupied candidate grid/site: $grid $subsite"}
            }
        }
    }
    $chosen.Add($name,[pscustomobject]@{name=$name;grid=$grid;subsite=$subsite;expected_type=$expected[$name];native_name=$null;native_type=$null;native_name_verified=$false;native_type_verified=$false;site_compatible=$false;native_fixed=$false})
    if(!$chosenGrids.ContainsKey($grid)){$chosenGrids.Add($grid,[Collections.Generic.List[object]]::new())}
    $chosenGrids[$grid].Add($chosen[$name])
}
if ($chosen.Count -ne $scope.Count) {
    $countName=if($Profile -eq 'ten'){'ten'}else{[string]$scope.Count}
    throw "Expected exactly $countName distinct approved leaves; got $($chosen.Count)."
}

# Native PDS text dumps use an 'Inst' record followed by 'name;gopType'. A name
# substring in Verilog, comments, a path report or an old type inventory is not
# equivalent evidence. Only the exact name or the observed terminal _perm
# spelling is accepted, and ambiguity/duplicate records are fatal.
$records=New-OrdinalMap
if ($null -ne $native) {
$lines=(Get-Utf8Text $native) -split '\r?\n'
for ($i=0; $i -lt $lines.Length-1; $i++) {
    if ($lines[$i].Trim() -cne 'Inst') { continue }
    if ($lines[$i+1] -cnotmatch '^([^;\r\n]+);(gop[A-Za-z0-9_]+)\s*$') {
        throw "Malformed native Inst record at line $($i+2)."
    }
    $name=$Matches[1]; $type=$Matches[2]
    if ($records.ContainsKey($name)) { throw "Duplicate native name: $name" }
    $records.Add($name,$type)
}
if (!$records.Count) { throw 'No native GOP Inst records; simulation primitive Verilog is not GOP evidence.' }
foreach ($leaf in $chosen.Values) {
    $aliases=@($leaf.name)
    if (!$leaf.name.EndsWith('_perm',[StringComparison]::Ordinal)) { $aliases+=($leaf.name+'_perm') }
    $found=@($aliases | Where-Object { $records.ContainsKey($_) })
    if ($found.Count -ne 1) { throw "Missing or ambiguous native leaf: $($leaf.name)" }
    $leaf.native_name=$found[0]; $leaf.native_type=$records[$found[0]]
    if ($leaf.native_type -cne $leaf.expected_type) { throw "Wrong GOP type: $($leaf.name): $($leaf.native_type), expected $($leaf.expected_type)" }
    $leaf.native_name_verified=$true; $leaf.native_type_verified=$true
}
}

# Publish only after validation and before/after input hashes agree. Existing
# outputs are never overwritten; an audit is the completion marker for wrappers.
$out=[IO.Path]::GetFullPath($OutputDir)
$mergedPath=Join-Path $out 'mini_raw8_geometry.pcf'
$auditPath=Join-Path $out 'ddr_placement_audit.json'
if ((Test-Path -LiteralPath $mergedPath) -or (Test-Path -LiteralPath $auditPath)) { throw 'Output already exists; choose a fresh OutputDir.' }
foreach ($item in $inputs) {
    if ((Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash -cne $item.sha256) { throw "Input changed during validation: $($item.path)" }
}
[IO.Directory]::CreateDirectory($out) | Out-Null
$append=[Text.Encoding]::UTF8.GetBytes("`n# EXPERIMENTAL: text-validated DDR delta; native checks pending.`n# Board prefix preserved verbatim; this file is not release qualification.`n"+$deltaText+"`n")
$stream=[IO.File]::Open($mergedPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $stream.Write($base.bytes,0,$base.bytes.Length); $stream.Write($append,0,$append.Length) }
finally { $stream.Dispose() }
$audit=[ordered]@{
    schema_version=1;profile=$Profile;profile_helper=[ordered]@{path=$scopeEvidence.path;sha256=$scopeEvidence.sha256};status='TEXT_VALIDATED_NATIVE_CHECKS_PENDING';created_utc=[DateTime]::UtcNow.ToString('o')
    text_validated=$true;native_checks_pending=$true;release_qualified=$false
    inputs=@($inputs | ForEach-Object { [ordered]@{path=$_.path;sha256=$_.sha256;bytes=$_.length} })
    source_inputs_unchanged=$true;board_prefix_bytes=$base.length;board_prefix_sha256=$base.sha256
    board_port_count=$portCount;hdmi_reset_sites=@($resetNames | ForEach-Object { $baseSites[$_] })
    leaves=@($chosen.Values | Sort-Object name)
    output=[ordered]@{path=$mergedPath;sha256=(Get-FileHash -LiteralPath $mergedPath -Algorithm SHA256).Hash}
    evidence_kind=$(if ($null -ne $native) { 'native Inst/name;gopType records supplied by caller' } else { 'none; experimental text-only merge' })
    map_netlist_provenance_verified=$false;native_placement_legalized=$false;timing_verified=$false
    limitations=@('Caller must bind NativeNetlist to the new map; file hashes alone do not establish that relationship.',
        'No PDS process is launched. Architecture/site and shared-packing legality require native PCE/PNR validation.',
        'critical37 permits distinct subsite anchors in shared CLMs only as a native packing experiment; ten retains whole-grid exclusion.',
        'Old native GOP equality is not established; no no_check or automatic conflict override.')
    required_native_checks=@('Native placement must confirm every exact profile leaf is fixed at the requested site.',
        'Reject missing-name, incompatible-type/site and placement-constraint errors; absence of errors alone is not proof of fixed leaves.',
        'After routing, obtain new native name/type evidence and bind it to this map/PCF by hashes; simulation Verilog alone is not a GOP dump.',
        'Complete multi-corner final STA and all normal release gates; this merge never grants release qualification.')
}
$json=$audit | ConvertTo-Json -Depth 8
$writer=[IO.StreamWriter]::new([IO.File]::Open($auditPath,[IO.FileMode]::CreateNew),[Text.UTF8Encoding]::new($false))
try { $writer.WriteLine($json) } finally { $writer.Dispose() }
[pscustomobject]@{MergedPcf=$mergedPath;AuditJson=$auditPath;LeafCount=$chosen.Count;Status=$audit.status;TextValidated=$true;NativeChecksPending=$true}
