# Purpose: verify the explicitly selected DDR profile against a fresh native export
# and matching PNR GOP dump. This gate does not run PDS or grant timing/release
# qualification. The caller must supply the current PNR companion .netlist,
# never an old golden file or simulation primitive Verilog.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AuditJson,
    [Parameter(Mandatory=$true)][string]$NativePcf,
    [Parameter(Mandatory=$true)][string]$NativeNetlist,
    [Parameter(Mandatory=$true)][string]$RoutedDb,
    [Parameter(Mandatory=$true)][string]$MapAdf,
    [Parameter(Mandatory=$true)][string]$MappedPcf,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateSet('ten','critical37')][string]$Profile='ten'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Evidence([string]$Role,[string]$Path) {
    $path=(Resolve-Path -LiteralPath $Path).Path
    [pscustomobject]@{role=$Role;path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
function OrdinalMap { ,([Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)) }
function Need([bool]$Test,[string]$Message) { if (!$Test) { throw $Message } }
function Aliases([string]$Name) {
    $Name
    if (!$Name.EndsWith('_perm',[StringComparison]::Ordinal)) { $Name+'_perm' }
}
$output=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'OutputPath already exists; refusing overwrite.' }
$manifest=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$failure=$null
try {
    # Snapshot hashes before parsing; check the merge's original sources as
    # well as every native physical input again before publishing the result.
    foreach ($pair in @(@('merge_audit',$AuditJson),@('native_pcf',$NativePcf),@('native_netlist',$NativeNetlist),@('routed_db',$RoutedDb),@('map_adf',$MapAdf),@('mapped_pcf',$MappedPcf),@('verifier',$PSCommandPath),@('profile_helper',(Join-Path $PSScriptRoot 'geometry_ddr_scope.ps1')),@('inspector',(Join-Path $PSScriptRoot 'inspect_geometry_ddr_placement.tcl')))) {
        $manifest.Add((Evidence $pair[0] $pair[1]))
    }
    $byRole=OrdinalMap
    foreach ($item in $manifest) { $byRole.Add($item.role,$item) }
    $audit=Get-Content -LiteralPath $AuditJson -Raw | ConvertFrom-Json
    # Hash the helper before evaluating its fixed scope; reject audit/profile
    # downgrade or rewritten sites before reading any purported native result.
    . $byRole['profile_helper'].path
    Assert-GeometryDdrAuditPolicy $audit $Profile $byRole['profile_helper'].path
    Need ($audit.output.sha256 -ceq $byRole['mapped_pcf'].sha256) 'MappedPcf differs from the merge output.'
    $mapMatches=@($audit.inputs | Where-Object { $_.sha256 -ceq $byRole['map_adf'].sha256 -and [IO.Path]::GetExtension($_.path) -ieq '.adf' })
    Need ($mapMatches.Count -eq 1) 'MapAdf not uniquely hash-bound in merge audit; merge with -MapAdf.'
    foreach ($source in $audit.inputs) {
        $record=Evidence 'merge_source' $source.path
        Need ($record.sha256 -ceq $source.sha256) "Merge input changed: $($source.path)"
        $manifest.Add($record)
    }

    # The wrapper emits this manifest AFTER successful native execution, fresh
    # output/no-error checks, and before/after hashes. Tcl cannot safely emit it
    # because PDS queues native commands after parsing and evaluates Tcl twice.
    $exportManifest=Join-Path (Split-Path -Parent $byRole['native_pcf'].path) 'native_export_manifest.tsv'
    $manifest.Add((Evidence 'native_export_manifest' $exportManifest))
    $exportRows=@(Import-Csv -LiteralPath $exportManifest -Delimiter "`t")
    foreach ($role in @('routed_db','map_adf','mapped_pcf','inspector','native_pcf')) {
        $rows=@($exportRows | Where-Object { $_.role -ceq $role })
        Need ($rows.Count -eq 1 -and $rows[0].sha256 -ceq $byRole[$role].sha256) "Native export is not bound to current $role."
        $exportSource=Evidence 'export_source' $rows[0].path
        Need ($exportSource.sha256 -ceq $rows[0].sha256) "Export source changed: $($rows[0].path)"
        $manifest.Add($exportSource)
    }

    # Native generate_constraint emits optional -no_check; read this as output
    # syntax only. The loaded candidate PCF must still never contain no_check.
    $mappedText=[IO.File]::ReadAllText($MappedPcf)
    foreach ($line in ($mappedText -split '\r?\n')) {
        if ($line.Trim() -and !$line.Trim().StartsWith('#')) { Need ($line -notmatch '(?i)no_check') 'Candidate contains no_check.' }
    }
    $actual=OrdinalMap
    foreach ($line in ([IO.File]::ReadAllLines($NativePcf))) {
        if ($line -cnotmatch '^def_inst_site\s') { continue }
        Need ($line -cmatch '^def_inst_site\s+\{([^{};]+)\}\s+(\S+)(?:\s+(?!-)(\S+))?(?:\s+-no_check)?\s*$') "Malformed native PCF site: $line"
        $name=$Matches[1]; $grid=$Matches[2]; $subsite=$(if ($Matches.ContainsKey(3)) { $Matches[3] } else { '' })
        Need (!$actual.ContainsKey($name)) "Duplicate native PCF name: $name"
        $actual.Add($name,[pscustomobject]@{grid=$grid;subsite=$subsite})
    }
    $types=OrdinalMap
    $lines=[IO.File]::ReadAllLines($NativeNetlist)
    for ($i=0;$i -lt $lines.Length-1;$i++) {
        if ($lines[$i].Trim() -cne 'Inst') { continue }
        Need ($lines[$i+1] -cmatch '^([^;\r\n]+);(gop[A-Za-z0-9_]+)\s*$') 'Malformed native GOP record.'
        $name=$Matches[1]; $type=$Matches[2]
        Need (!$types.ContainsKey($name)) "Duplicate native GOP name: $name"
        $types.Add($name,$type)
    }
    Need ($types.Count -gt 0) 'No native GOP records; simulation Verilog is not a GOP type dump.'

    # Scope is defined by pre-PNR PCF names (LUT6_inst, without terminal _perm).
    # Aliases above allow exactly one original/post-permutation output record.
    # Do not infer an arbitrary suffix rename or accept both names ambiguously.
    $expected=OrdinalMap
    $scope=Get-GeometryDdrScope $Profile
    foreach($leaf in $scope.Values){$expected.Add($leaf.name,$leaf.expected_type)}
    $seen=OrdinalMap
    foreach ($leaf in $audit.leaves) {
        Need ($expected.ContainsKey($leaf.name) -and !$seen.ContainsKey($leaf.name)) "Invalid/duplicate audit leaf: $($leaf.name)"
        $seen.Add($leaf.name,$true)
        Need ($leaf.expected_type -ceq $expected[$leaf.name]) 'Altered expected GOP type in merge audit.'
        # Bind each audited request to the actual loaded candidate, not just
        # to user-editable JSON fields describing a different target site.
        $candidatePattern='(?m)^def_inst_site\s+\{'+[regex]::Escape($leaf.name)+'\}\s+'+[regex]::Escape($leaf.grid)+'\s+'+[regex]::Escape($leaf.subsite)+'\s*\r?$'
        Need ([regex]::Matches($mappedText,$candidatePattern).Count -eq 1) "Audited leaf differs from loaded candidate: $($leaf.name)"
        $pcfMatches=@((Aliases $leaf.name) | Where-Object { $actual.ContainsKey($_) })
        $typeMatches=@((Aliases $leaf.name) | Where-Object { $types.ContainsKey($_) })
        Need ($pcfMatches.Count -eq 1) "Missing/ambiguous actual placement: $($leaf.name)"
        Need ($typeMatches.Count -eq 1) "Missing/ambiguous actual type: $($leaf.name)"
        $position=$actual[$pcfMatches[0]]
        Need ($position.grid -ceq $leaf.grid -and $position.subsite -ceq $leaf.subsite) "Actual site mismatch: $($leaf.name)"
        Need ($types[$typeMatches[0]] -ceq $expected[$leaf.name]) "Actual GOP type mismatch: $($leaf.name)"
        $checks.Add([pscustomobject]@{name=$leaf.name;native_pcf_name=$pcfMatches[0];native_type_name=$typeMatches[0];type=$types[$typeMatches[0]];grid=$position.grid;subsite=$position.subsite;passed=$true})
    }
    foreach ($item in $manifest) {
        Need ((Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash -ceq $item.sha256) "Input changed during verification: $($item.path)"
    }
} catch { $failure=$_.Exception.Message }

# Emit failed results too, and fail the process/caller after writing them. A
# passing physical comparison is NOT a timing or board-functional release gate.
$result=[ordered]@{schema_version=1;profile=$Profile;passed=($null -eq $failure);error=$failure;created_utc=[DateTime]::UtcNow.ToString('o');source_inputs_unchanged=($null -eq $failure);inputs=@($manifest);physical_hash_manifest=@($manifest);leaves=@($checks);timing_verified=$false;release_qualified=$false;native_export_provenance_verified_by_this_script=$false;native_netlist_provenance='Wrapper must establish successful fresh native export and current PNR companion lineage; this verifier records hashes and compares contents, not filename-based provenance.'}
[IO.Directory]::CreateDirectory((Split-Path -Parent $output)) | Out-Null
$writer=[IO.StreamWriter]::new([IO.File]::Open($output,[IO.FileMode]::CreateNew),[Text.UTF8Encoding]::new($false))
try { $writer.WriteLine(($result | ConvertTo-Json -Depth 8)) } finally { $writer.Dispose() }
if ($failure) { throw "DDR placement verification failed: $failure (audit: $output)" }
[pscustomobject]@{Passed=$true;LeafCount=$checks.Count;OutputPath=$output}
