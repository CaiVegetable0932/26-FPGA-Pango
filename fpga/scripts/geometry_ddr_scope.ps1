# Purpose: immutable reviewed experiment allowlists, not a user-extensible profile.
# critical37 uses current PNR13 GOP expectations at historic solved sites. No old
# GOP equality or new-map legality is asserted. Native PCE/PNR must prove both.
# Sources: ddr_slice_audit_20261007_093224/critical37_expected_current_types.json
# and critical37_experimental_NOT_APPLIED.pcf (198997cc...e2746d60e).
function Get-GeometryDdrScope {
    param([ValidateSet('ten','critical37')][string]$Profile='ten')
    $prefix='I_ips_ddr_top/u_ddrphy_top/'
    $slice=$prefix+'ddrphy_slice_top/i_dqs_group[1].ddrphy_data_slice/'
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    # Compact constant table: relative path|GOP|tile|subsite|legacy membership.
    # Every row is a reviewed literal; no file/config input can extend the scope.
    $rows=@'
dfi/phy_wrdata_d[10]/opit_0_inv_L6Q|gopLUT6Q|CLMA_303_907|FYD|0
dfi/phy_wrdata_d[11]/opit_0_inv_L6Q|gopLUT6Q|CLMA_345_942|FYD|0
dfi/phy_wrdata_d[13]/opit_0_inv_L6Q|gopLUT6Q|CLMA_357_937|FYD|0
ddrphy_dqs_rddata_align/ck_dqs_diff[1]/opit_0_inv_L6QL5Q1|gopLUT6QL5Q|CLMA_357_858|FYA|1
ddrphy_dqs_rddata_align/rddata_r1[18]/opit_0_inv_srl|gopSRL2|CLMA_303_907|FFAPP2|0
ddrphy_dqs_rddata_align/rddata_r1[22]/opit_0_inv_srl|gopSRL2|CLMS_345_913|FFAPP1|0
ddrphy_dqs_rddata_align/rddata_r1[28]/opit_0_inv_srl|gopSRL2|CLMA_351_912|FFAPP0|0
ddrphy_dqs_rddata_align/rddata_r1[31]/opit_0_inv_srl|gopSRL2|CLMA_357_877|FFAPP2|0
ddrphy_dqs_rddata_align/rddata_r1[40]/opit_0_inv_srl|gopSRL2|CLMS_351_943|FFAPP0|0
ddrphy_dqs_rddata_align/rddata_r1[41]/opit_0_inv_srl|gopSRL2|CLMA_357_888|FFAPP2|0
ddrphy_dqs_rddata_align/rddata_r1[42]/opit_0_inv_srl|gopSRL2|CLMA_357_912|FFAPP0|0
ddrphy_dqs_rddata_align/rddata_r1[44]/opit_0_inv_srl|gopSRL2|CLMA_357_925|FFAPP2|0
ddrphy_dqs_rddata_align/slip_en/opit_0_inv_L6QL5Q|gopLUT6QL5Q|CLMA_357_841|FYB|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[1]/LUT6_inst|gopLUT6|CLMA_357_858|FYB|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[29]/LUT6_inst|gopLUT6|CLMA_315_894|FYD|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[31]/LUT6_inst|gopLUT6|CLMS_309_901|FYA|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[33]/LUT6_inst|gopLUT6|CLMS_309_895|FYB|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[35]/LUT6_inst|gopLUT6|CLMA_315_900|FYC|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[37]/LUT6_inst|gopLUT6|CLMA_351_930|FYB|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[39]/LUT6_inst|gopLUT6|CLMS_345_931|FYB|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[42]/LUT6_inst|gopLUT6|CLMA_303_961|FYD|1
ddrphy_wdata_path_adj/adj_wrdata_mask_3[43]/LUT6_inst|gopLUT6|CLMS_345_931|FYA|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[47]/LUT6_inst|gopLUT6|CLMA_315_912|FYD|1
ddrphy_wdata_path_adj/adj_wrdata_mask_3[53]/LUT6_inst|gopLUT6|CLMA_357_924|FYA|1
ddrphy_wdata_path_adj/adj_wrdata_mask_3[55]/LUT6_inst|gopLUT6|CLMA_357_924|FYB|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[57]/LUT6_inst|gopLUT6|CLMA_351_930|FYA|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[59]/LUT6_inst|gopLUT6|CLMS_351_931|FYD|1
ddrphy_wdata_path_adj/adj_wrdata_mask_3[5]/gateop|gopLUT6|CLMA_357_877|FYA|0
ddrphy_wdata_path_adj/adj_wrdata_mask_3[68]/LUT6_inst|gopLUT6|CLMA_357_991|FYA|1
ddrphy_wdata_path_adj/adj_wrdata_mask_3[73]/LUT6_inst|gopLUT6|CLMA_357_912|FYB|1
ddrphy_wdata_path_adj/phy_wrdata_r[20]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_315_913|FYC|0
ddrphy_wdata_path_adj/phy_wrdata_r[22]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_315_913|FYA|0
ddrphy_wdata_path_adj/phy_wrdata_r[36]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_333_912|FYC|0
ddrphy_wdata_path_adj/phy_wrdata_r[42]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_357_937|FYC|0
ddrphy_wdata_path_adj/phy_wrdata_r[44]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_357_949|FYC|1
ddrphy_wdata_path_adj/phy_wrdata_r[57]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_357_1002|FYC|1
ddrphy_wdata_path_adj/phy_wrdata_r[58]/opit_0_inv_L6QQ|gopLUT6QQ|CLMA_357_930|FYD|1
'@
    foreach($line in ($rows -split '\r?\n')) {
        $f=$line.Split('|')
        if($Profile -eq 'ten' -and $f[4] -ne '1'){continue}
        $name=if($f[0].StartsWith('dfi/')){$prefix+'ddrphy_'+$f[0]}else{$slice+$f[0]}
        $map.Add($name,[pscustomobject]@{name=$name;expected_type=$f[1];grid=$f[2];subsite=$f[3]})
    }
    return ,$map
}

# Only critical37 permits distinct subsite experiments in one tile. This is a
# syntax/type filter, not a packing-footprint model; native legalization wins.
function Assert-GeometryDdrSite {
    param($Leaf,[string]$Grid,[string]$Subsite,[string]$Profile)
    $validSub=if($Leaf.expected_type -ceq 'gopSRL2'){$Subsite -cmatch '^FFAPP[0-3]$'}else{$Subsite -cmatch '^FY[A-D]$'}
    if($Grid -cnotmatch '^CLM[AS]_\d+_\d+$' -or !$validSub){throw "Unsupported candidate site: $Grid $Subsite"}
    if($Profile -eq 'critical37' -and ($Grid -cne $Leaf.grid -or $Subsite -cne $Leaf.subsite)){
        throw "Unapproved profile site: $($Leaf.name): $Grid $Subsite"
    }
}

# Bind the selected policy to the merge audit, not to a user-editable leaf count.
# Legacy audits without a profile are ten only; critical37 always requires the
# current helper's path/hash in both its dedicated field and input manifest.
function Assert-GeometryDdrAuditPolicy {
    param($Audit,[ValidateSet('ten','critical37')][string]$Profile,[string]$HelperPath)
    $auditProfile=if($Audit.PSObject.Properties.Name -contains 'profile'){$Audit.profile}else{'ten'}
    if($auditProfile -cne $Profile){throw 'DDR audit profile does not match explicit selected profile.'}
    $scope=Get-GeometryDdrScope $Profile
    if($Audit.schema_version -ne 1 -or $Audit.text_validated -ne $true -or $Audit.leaves.Count -ne $scope.Count){throw 'Invalid merge audit schema/scope.'}
    $hasHelper=$Audit.PSObject.Properties.Name -contains 'profile_helper'
    if($Profile -eq 'critical37' -and !$hasHelper){throw 'Missing profile helper hash binding.'}
    if($hasHelper) {
        $path=(Resolve-Path -LiteralPath $HelperPath).Path
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if([IO.Path]::GetFullPath($Audit.profile_helper.path) -ine $path -or $Audit.profile_helper.sha256 -cne $hash){throw 'Profile helper hash/path mismatch.'}
        $bound=@($Audit.inputs | Where-Object {[IO.Path]::GetFullPath($_.path) -ieq $path -and $_.sha256 -ceq $hash})
        if($bound.Count -ne 1){throw 'Profile helper not uniquely bound in merge inputs.'}
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($leaf in $Audit.leaves) {
        if(!$scope.ContainsKey($leaf.name) -or !$seen.Add($leaf.name)){throw "Invalid/duplicate audit leaf: $($leaf.name)"}
        if($leaf.expected_type -cne $scope[$leaf.name].expected_type){throw 'Altered expected GOP type in merge audit.'}
        Assert-GeometryDdrSite $scope[$leaf.name] $leaf.grid $leaf.subsite $Profile
    }
}
