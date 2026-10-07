# Purpose: offline profile/merge/native-evidence parser regressions. All outputs
# are synthetic fixtures under fpga/build, never native placement/STA evidence.
# Default-ten historical regressions remain separate and unchanged.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$fpga=Split-Path $PSScriptRoot -Parent
$run=Join-Path $fpga ('build/ddr_profile_tests_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
[IO.Directory]::CreateDirectory($run) | Out-Null
$enc=[Text.UTF8Encoding]::new($false)
$merge=Join-Path $PSScriptRoot 'merge_geometry_ddr_pcf.ps1'
$verify=Join-Path $PSScriptRoot 'verify_geometry_ddr_placement.ps1'
$helper=Join-Path $PSScriptRoot 'geometry_ddr_scope.ps1'
. $helper
$scope=Get-GeometryDdrScope critical37
$results=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function Fixture([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$enc);return $Path}
function Record([string]$Name){$results.Add([pscustomobject]@{name=$Name;passed=$true})}

# Independent audit-derived literals must agree with the compiled allowlist.
# The historical files are read-only comparison inputs, never validation of a
# new mapped design. A hand-edited helper cannot silently widen the experiment.
$auditDir=Join-Path $fpga 'build/ddr_slice_audit_20261007_093224'
$expected=Get-Content (Join-Path $auditDir 'critical37_expected_current_types.json') -Raw | ConvertFrom-Json
$delta=Join-Path $auditDir 'critical37_experimental_NOT_APPLIED.pcf'
$deltaText=[IO.File]::ReadAllText($delta)
Check ($scope.Count -eq 37 -and $expected.leaves.Count -eq 37) 'Expected exactly critical37'
foreach($leaf in $expected.leaves){
    Check ($scope.ContainsKey($leaf.name)) "Missing approved name $($leaf.name)"
    $literal=$scope[$leaf.name]
    Check ($literal.expected_type -ceq $leaf.expected_type -and $literal.grid -ceq $leaf.grid -and $literal.subsite -ceq $leaf.subsite) 'Allowlist differs from approved audit'
}
Record '37_exact_name_type_site_match_independent_audit'
Check ((Get-GeometryDdrScope ten).Count -eq 10) 'Default ten lost'
Record 'default_ten_count'
$unknown=$false
try {Get-GeometryDdrScope unapproved | Out-Null}catch{$unknown=$true}
Check $unknown 'Arbitrary profile accepted'
Record 'unknown_profile_rejected'

# Minimal board fixture preserves board ports and all four required reset sites.
# It is deliberately labelled synthetic; neither ADF fixture is a usable DB.
$baseText=@'
# SYNTHETIC PARSER FIXTURE ONLY
def_port {test_clk} LOC=A1
def_inst_site {u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv} CLMA_21_378 FF0
def_inst_site {u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset/opit_0_inv} CLMA_21_402 FF0
def_inst_site {u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset/opit_0_inv} CLMA_21_426 FF0
def_inst_site {u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv} CLMA_21_450 FF0
'@
$base=Fixture (Join-Path $run 'SYNTHETIC_board.pcf') $baseText
$map=Fixture (Join-Path $run 'SYNTHETIC_map.adf') 'NOT A NATIVE MAP'
$db=Fixture (Join-Path $run 'SYNTHETIC_pnr.adf') 'NOT A NATIVE PNR'
$merged=& $merge -Profile critical37 -MapPcf $base -MapAdf $map -DeltaPcf $delta -OutputDir (Join-Path $run 'merged')
$audit=Get-Content $merged.AuditJson -Raw | ConvertFrom-Json
Check ($audit.profile -ceq 'critical37' -and $audit.leaves.Count -eq 37 -and $audit.native_checks_pending -and !$audit.release_qualified -and !$audit.native_placement_legalized) 'Unsafe merge result'
Check ([IO.File]::ReadAllText($merged.MergedPcf).StartsWith($baseText)) 'Board prefix changed'
Check (@($audit.leaves | Group-Object grid | Where-Object Count -gt 1).Count -eq 9) 'Expected nine shared CLMs'
Check ($audit.profile_helper.sha256 -ceq (Get-FileHash $helper).Hash) 'Helper hash not bound'
Record 'critical37_merge_nine_shared_clms_pending_native'

# Negative merge cases must never publish a candidate. Different legal subsite
# anchors are accepted only if the fixed critical37 table explicitly allows it.
function BadMerge([string]$Name,[string]$Text,[string]$Expected,[string]$BaseOverride='',[string]$Profile='critical37'){
    $file=Fixture (Join-Path $run ($Name+'.pcf')) $Text
    $out=Join-Path $run $Name
    $args=@{Profile=$Profile;MapPcf=$base;MapAdf=$map;DeltaPcf=$file;OutputDir=$out}
    if($BaseOverride){$args.MapPcf=Fixture (Join-Path $run ($Name+'_base.pcf')) $BaseOverride}
    $err=$null
    try{& $merge @args | Out-Null}catch{$err=$_.Exception.Message}
    Check ($null -ne $err -and $err -match $Expected) "$Name wrong error: $err"
    Check (!(Test-Path (Join-Path $out 'mini_raw8_geometry.pcf'))) "$Name published invalid output"
    Record $Name
}
$commands=@($deltaText -split '\r?\n' | Where-Object {$_ -cmatch '^def_inst_site'})
BadMerge 'duplicate_name' ($deltaText+"`n"+$commands[0]) 'Duplicate/conflicting leaf'
BadMerge 'missing_leaf' ($commands[1..36] -join "`n") 'exactly 37'
BadMerge 'unknown_leaf' ($deltaText.Replace('phy_wrdata_d[10]','phy_wrdata_d[12]')) 'Out-of-scope'
BadMerge 'postperm_input_name' ($deltaText.Replace('/LUT6_inst}','/LUT6_inst_perm}')) 'Out-of-scope'
BadMerge 'wrong_clm_site' ($deltaText.Replace('CLMA_303_907 FYD','CLMA_303_908 FYD')) 'Unapproved profile site'
BadMerge 'wrong_lut_subsite' ($deltaText.Replace('CLMA_303_907 FYD','CLMA_303_907 FYC')) 'Unapproved profile site'
BadMerge 'non_clm' ($deltaText.Replace('CLMA_303_907 FYD','IOB_303_907 FYD')) 'Unsupported candidate site'
BadMerge 'lut_at_ffapp' ($deltaText.Replace('CLMA_303_907 FYD','CLMA_303_907 FFAPP0')) 'Unsupported candidate site'
BadMerge 'srl_at_fy' ($deltaText.Replace('CLMA_303_907 FFAPP2','CLMA_303_907 FYA')) 'Unsupported candidate site'
BadMerge 'srl_out_of_range' ($deltaText.Replace('CLMA_303_907 FFAPP2','CLMA_303_907 FFAPP4')) 'Unsupported candidate site'
BadMerge 'unapproved_srl_subsite' ($deltaText.Replace('CLMA_303_907 FFAPP2','CLMA_303_907 FFAPP1')) 'Unapproved profile site'
BadMerge 'no_check' ($deltaText.Replace('CLMA_303_907 FYD','CLMA_303_907 FYD -no_check')) 'Forbidden no_check'
BadMerge 'command_injection' ($deltaText+"`nputs injected") 'Unsupported delta syntax'
BadMerge 'exact_base_conflict' $deltaText 'Occupied candidate' ($baseText+"`ndef_inst_site {other} CLMA_303_907 FYD")
BadMerge 'whole_tile_base_conflict' $deltaText 'Occupied candidate' ($baseText+"`ndef_inst_site {other} CLMA_303_907")
BadMerge 'default_does_not_auto_adopt_critical37' $deltaText 'Out-of-scope' '' 'ten'
$sharedBase=Fixture (Join-Path $run 'shared_distinct_base.pcf') ($baseText+"`ndef_inst_site {other} CLMA_303_907 FYA")
& $merge -Profile critical37 -MapPcf $sharedBase -MapAdf $map -DeltaPcf $delta -OutputDir (Join-Path $run 'shared_distinct_base') | Out-Null
Record 'distinct_base_subsite_allowed_as_experiment'

# Synthetic PNR exports exercise every per-leaf type/location comparison and
# provenance gate. Passing these tests is NOT passing actual PNR placement.
function NativeCase([string]$Name,[string]$Mutation,[string]$ErrorPattern=''){
    $dir=Join-Path $run $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $copy=Get-Content $merged.AuditJson -Raw | ConvertFrom-Json
    $pcf=@('# SYNTHETIC NOT NATIVE')
    $net=@('# SYNTHETIC NOT NATIVE')
    foreach($leaf in $copy.leaves){
        $pcf+='def_inst_site {'+$leaf.name+'} '+$leaf.grid+' '+$leaf.subsite+' -no_check'
        $net+=@('Inst',($leaf.name+'_perm;'+$leaf.expected_type))
    }
    $args=@{Profile='critical37';AuditJson=$merged.AuditJson;NativePcf=(Join-Path $dir 'actual_ddr.pcf');NativeNetlist=(Join-Path $dir 'SYNTHETIC.netlist');RoutedDb=$db;MapAdf=$map;MappedPcf=$merged.MergedPcf;OutputPath=(Join-Path $dir 'result.json')}
    switch($Mutation){
        'unpermuted' {$net=@($net | ForEach-Object {$_ -replace '_perm;',';'})}
        'wrong_type' {$net[2]=$net[2] -replace ';gop\w+',';gopQ'}
        'srl_wrong_type' {$net=@($net | ForEach-Object {$_ -replace ';gopSRL2',';gopQ'})}
        'wrong_site' {$pcf[1]=$pcf[1] -replace 'CLM[AS]_\d+_\d+','CLMA_999_999'}
        'wrong_srl_site' {$pcf=@($pcf | ForEach-Object {$_ -replace 'FFAPP2','FFAPP3'})}
        'missing_dfi' {$pcf=@($pcf | Where-Object {$_ -notmatch '/ddrphy_dfi/'})}
        'duplicate_position' {$pcf+=$pcf[1]}
        'duplicate_type' {$net+=@('Inst',$net[2])}
        'ambiguous_type' {$net+=@('Inst',($copy.leaves[0].name+';'+$copy.leaves[0].expected_type))}
        'missing_type' {$net=$net[0..0]+$net[3..($net.Count-1)]}
        'tampered_type' {$copy.leaves[0].expected_type='gopQ'}
        'tampered_site' {$copy.leaves[0].grid='CLMA_999_999'}
        'tampered_profile' {$copy.profile='ten'}
        'stale_helper' {$copy.profile_helper.sha256='0'*64}
        'missing_helper' {$copy.PSObject.Properties.Remove('profile_helper')}
        'unbound_helper' {$copy.inputs=@($copy.inputs | Where-Object {$_.path -ine $helper})}
        'default_profile' {$args.Remove('Profile')}
    }
    if($Mutation -match '^tampered_|helper$'){$args.AuditJson=Fixture (Join-Path $dir 'audit.json') ($copy | ConvertTo-Json -Depth 10)}
    Fixture $args.NativePcf ($pcf -join "`n") | Out-Null
    Fixture $args.NativeNetlist ($net -join "`n") | Out-Null
    $rows=@()
    foreach($pair in @(@('routed_db',$db),@('map_adf',$map),@('mapped_pcf',$merged.MergedPcf),@('native_pcf',$args.NativePcf),@('inspector',(Join-Path $PSScriptRoot 'inspect_geometry_ddr_placement.tcl')))){
        $rows+=[pscustomobject]@{role=$pair[0];path=$pair[1];sha256=(Get-FileHash -LiteralPath $pair[1]).Hash}
    }
    if($Mutation -eq 'stale_export'){$rows[0].sha256='0'*64}
    $rows | Export-Csv (Join-Path $dir 'native_export_manifest.tsv') -Delimiter "`t" -NoTypeInformation
    $err=$null
    try{& $verify @args | Out-Null}catch{$err=$_.Exception.Message}
    $result=Get-Content $args.OutputPath -Raw | ConvertFrom-Json
    if($ErrorPattern){Check (!$result.passed -and $null -ne $err -and $err -match $ErrorPattern) "$Name wrong result: $err"}
    else{Check ($result.passed -and $null -eq $err -and $result.leaves.Count -eq 37) "$Name unexpectedly failed: $err"}
    Check (!$result.timing_verified -and !$result.release_qualified) 'Test claimed release qualification'
    Record $Name
}
NativeCase 'synthetic37_exact' ''
NativeCase 'synthetic37_unpermuted' 'unpermuted'
NativeCase 'native_wrong_type' 'wrong_type' 'Actual GOP type mismatch'
NativeCase 'native_wrong_srl_type' 'srl_wrong_type' 'Actual GOP type mismatch'
NativeCase 'native_wrong_site' 'wrong_site' 'Actual site mismatch'
NativeCase 'native_wrong_srl_site' 'wrong_srl_site' 'Actual site mismatch'
NativeCase 'native_missing_dfi' 'missing_dfi' 'Missing/ambiguous actual placement'
NativeCase 'native_duplicate_position' 'duplicate_position' 'Duplicate native PCF name'
NativeCase 'native_duplicate_type' 'duplicate_type' 'Duplicate native GOP name'
NativeCase 'native_ambiguous_type' 'ambiguous_type' 'Missing/ambiguous actual type'
NativeCase 'native_missing_type' 'missing_type' 'Missing/ambiguous actual type'
NativeCase 'audit_type_tamper' 'tampered_type' 'Altered expected GOP type'
NativeCase 'audit_site_tamper' 'tampered_site' 'Unapproved profile site'
NativeCase 'audit_profile_tamper' 'tampered_profile' 'profile does not match'
NativeCase 'audit_stale_helper' 'stale_helper' 'Profile helper hash/path mismatch'
NativeCase 'audit_missing_helper' 'missing_helper' 'Missing profile helper'
NativeCase 'audit_unbound_helper' 'unbound_helper' 'not uniquely bound'
NativeCase 'verify_requires_explicit_profile' 'default_profile' 'profile does not match'
NativeCase 'stale_export_binding' 'stale_export' 'not bound to current routed_db'

# Resume preflight must reject profile/hash mismatch before a PDS executable
# could be invoked. A nonexistent PdsHome makes accidental fallthrough fail.
$checkpoint=Join-Path $run 'resume_rejected_checkpoint'
[IO.Directory]::CreateDirectory($checkpoint) | Out-Null
Fixture (Join-Path $checkpoint 'source_manifest.json') '[]' | Out-Null
Copy-Item $merged.AuditJson (Join-Path $checkpoint 'ddr_placement_audit.json')
$err=$null
try{& (Join-Path $PSScriptRoot 'resume_geometry_route.ps1') -Checkpoint $checkpoint -NewPlacementSeed 1 -PdsHome (Join-Path $run 'NO_PDS_INSTALLED') | Out-Null}catch{$err=$_.Exception.Message}
Check ($null -ne $err -and $err -match 'profile does not match') "Resume did not reject default/profile mismatch: $err"
Record 'resume_profile_preflight_no_pds'
$copy=Get-Content $merged.AuditJson -Raw | ConvertFrom-Json
$copy.profile_helper.sha256='0'*64
Fixture (Join-Path $checkpoint 'ddr_placement_audit.json') ($copy | ConvertTo-Json -Depth 10) | Out-Null
$err=$null
try{& (Join-Path $PSScriptRoot 'resume_geometry_route.ps1') -Profile critical37 -Checkpoint $checkpoint -NewPlacementSeed 1 -PdsHome (Join-Path $run 'NO_PDS_INSTALLED') | Out-Null}catch{$err=$_.Exception.Message}
Check ($null -ne $err -and $err -match 'Profile helper hash/path mismatch') "Resume stale helper not rejected: $err"
Record 'resume_helper_preflight_no_pds'

# Machine-readable evidence binds tests to all five implementation scripts.
$inputs=@(foreach($name in @('geometry_ddr_scope.ps1','merge_geometry_ddr_pcf.ps1','verify_geometry_ddr_placement.ps1','inspect_geometry_ddr_placement.tcl','resume_geometry_route.ps1','test_geometry_ddr_profiles.ps1')){
    $path=Join-Path $PSScriptRoot $name
    [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash}
})
$report=[ordered]@{status='PASS';case_count=$results.Count;cases=@($results);inputs=$inputs;native_run=$false;scope='Synthetic offline parser/provenance tests only; no native legality, STA, image or hardware qualification.'}
Fixture (Join-Path $run 'test_results.json') ($report | ConvertTo-Json -Depth 10) | Out-Null
Write-Output "PASS $($results.Count) cases TEST_DIR=$run"
