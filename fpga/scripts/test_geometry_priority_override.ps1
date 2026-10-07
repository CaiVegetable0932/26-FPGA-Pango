# Purpose: PS5.1/PS7 offline mutation tests, NEVER invokes PDS or the runner.
# All generated databases/projects/logs are labelled synthetic fixtures under
# a fresh fpga/build directory. They are not native implementation evidence.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$realScripts=$PSScriptRoot
$realFpga=Split-Path $realScripts -Parent
$testRun=Join-Path $realFpga ('build/priority_override_tests_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N'))
$fixtureFpga=Join-Path $testRun 'SYNTHETIC/fpga'
$utf8=[Text.UTF8Encoding]::new($false)
$results=[Collections.Generic.List[object]]::new()
function Put([string]$Path,[string]$Text) {
    # Test-owned fixture generation only; never writes existing project input.
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Json([string]$Path,$Value) {Put $Path ($Value | ConvertTo-Json -Depth 20)}
function Need([bool]$Condition,[string]$Message) {if(!$Condition){throw $Message}}
$names=@('resume_geometry_priority_route.ps1','resume_geometry_priority_route.tcl','check_geometry_priority_override.ps1')
foreach($name in $names){Put (Join-Path $fixtureFpga ('scripts/'+$name)) ([IO.File]::ReadAllText((Join-Path $realScripts $name)))}
$checker=Join-Path $fixtureFpga 'scripts/check_geometry_priority_override.ps1'
. $checker
$cp=Join-Path $fixtureFpga 'build/checkpoint_native_free'
$origin=Join-Path $fixtureFpga 'build/original_map'
$runDir=Join-Path $fixtureFpga 'build/run'
$candidate=Join-Path $fixtureFpga 'build/candidate.rcf'
$frozen=Join-Path $runDir 'routing/geometry_priority.rcf'
$allCommands=@(Get-PriorityNets | ForEach-Object {'def_route -prior_net {'+$_+'}'})
$originalRcf=Join-Path $fixtureFpga 'constraints/mini_raw8_dual/geometry_priority.rcf'
Put $originalRcf ($allCommands[0..7] -join "`n")
Put $candidate ($allCommands -join "`n"); Put $frozen ($allCommands -join "`n")
$sourcePaths=@($originalRcf)
foreach($rel in @(Get-PriorityFdc)){$p=Join-Path $fixtureFpga $rel; Put $p '# SYNTHETIC FDC only'; $sourcePaths+=@($p)}
$rtl=Join-Path $fixtureFpga 'rtl/fixture.v'; Put $rtl '// SYNTHETIC source'; $sourcePaths+=@($rtl)
# Independent board site literals exercise the no-DDR-delta rule. These are
# not functional native files; no tool is permitted to implement this fixture.
$pcfText=@'
# SYNTHETIC board fixture
def_region hdmi_reset_ck 3 4 73 75 {CLMA CLMS}
def_region hdmi_reset_d0 3 4 61 63 {CLMA CLMS}
def_region hdmi_reset_d1 3 4 65 67 {CLMA CLMS}
def_region hdmi_reset_d2 3 4 69 71 {CLMA CLMS}
def_inst_site {I_ips_ddr_top/u_ddrphy_top/ddrphy_reset_ctrl/ddrphy_ioclk_gate[0]/opit_0_inv} CLMA_357_354 FF3
def_inst_site {I_ips_ddr_top/u_ddrphy_top/ddrphy_reset_ctrl/ddrphy_ioclk_gate[1]/opit_0_inv} CLMA_357_660 FF3
def_inst_site {I_ips_ddr_top/u_ddrphy_top/u_ddrphy_cpd/cpd_inst} DDRPHY_CPD_369_466
def_inst_site {u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv} CLMA_21_378 FF0
def_inst_site {u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset/opit_0_inv} CLMA_21_402 FF0
def_inst_site {u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset/opit_0_inv} CLMA_21_426 FF0
def_inst_site {u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv} CLMA_21_450 FF0
def_inst_region {u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv} hdmi_reset_d0
def_inst_region {u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset/opit_0_inv} hdmi_reset_d1
def_inst_region {u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset/opit_0_inv} hdmi_reset_d2
def_inst_region {u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv} hdmi_reset_ck
'@
$pcfText+="`n"+((0..112 | ForEach-Object {'def_port {fixture_'+$_+'} LOC=N3'}) -join "`n")
$pcf=Join-Path $cp 'mini_raw8_geometry.pcf'; $originalPcf=Join-Path $origin 'original_map.pcf'
$map=Join-Path $cp 'mini_raw8_geometry_map.adf'; $originalMap=Join-Path $origin 'mini_raw8_geometry_map.adf'
$plc=Join-Path $cp 'mini_raw8_geometry_plc.adf'
Put $pcf $pcfText; Put $originalPcf $pcfText
Put $map 'SYNTHETIC MAP'; Put $originalMap 'SYNTHETIC MAP'; Put $plc 'SYNTHETIC PLC'
Put (Join-Path $runDir 'routed_snapshot/mini_raw8_geometry_pnr.adf') 'SYNTHETIC PNR'
$sources=@($sourcePaths | ForEach-Object {[pscustomobject]@{path=$_;sha256=(Get-PriorityHash $_)}})
foreach($folder in @($origin,$cp,$runDir)){Json (Join-Path $folder 'source_manifest.json') $sources}
$cmpPath=Join-Path $cp 'comparison.json'
Json $cmpPath ([pscustomobject]@{original_pcf=$originalPcf;copied_pcf=$pcf;sha256=(Get-PriorityHash $pcf);timing_budget_changed=$false})
$originAudit=Join-Path $origin 'ddr_placement_audit.json'
Json $originAudit ([pscustomobject]@{source_inputs_unchanged=$true;inputs=@(
 [pscustomobject]@{path=$originalPcf;sha256=(Get-PriorityHash $originalPcf)},
 [pscustomobject]@{path=$originalMap;sha256=(Get-PriorityHash $originalMap)})})
$state=[pscustomobject]@{schema_version=1;override_only=$true;timing_budget_changed=$false;
 source_inputs_unchanged=$true;release_qualified=$false;run=$runDir;checkpoint=$cp;candidate_rcf=$candidate;
 new_placement_seed=0;decongestion=6;stages=@('configure','pnr','sta','sbit');bindings=@();native_priority_route=$null}
function FileNode([string]$Path,[string]$Format) {return '(_file "'+$Path.Replace('\','/')+'" (_format '+$Format+'))'}
function MakeProject([string]$Stage,[int]$Seed=0) {
    # Native-shaped S-expressions, manually assembled independently from the
    # production Tcl; mutation cases must fail despite refreshed outer hashes.
    $files=@(Get-PriorityFdc | ForEach-Object {FileNode (Join-Path $fixtureFpga $_) 'fdc'})
    $files+=@(FileNode $frozen 'rcf'); $files+=@(FileNode $pcf 'pcf')
    $cmd=''
    if($Stage -eq 'pnr'){
        $nativeSeed=if($Seed -eq 0){2}else{$Seed}
        $cmd='(_command cmd_pnr (_option input_db_file '+(FileNode $map 'text')+')'
        if($Seed -eq 0){$cmd+=' (_option input_place_db_file '+(FileNode $plc 'text')+')'}
        $cmd+=' (_option force_to_run (_switch ON)) (_option action_timeout (_integer 180)) (_option congest_overlap_limit (_integer 20))'+
          ' (_option gplace_seed (_integer '+$nativeSeed+')) (_option plc_decongestion (_integer 6)) (_option mode (_string "performance"))'+
          ' (_option optimize_multi_corner_timing (_switch ON)) (_option fix_hold_violation (_switch ON))'+
          ' (_option fix_hold_violation_iterations (_integer 10)) (_option report_timing (_switch ON)))'
    }elseif($Stage -eq 'sta'){
        $cmd='(_command cmd_report_post_pnr_timing (_option input_db_file '+(FileNode (Join-Path $runDir 'routed_snapshot/mini_raw8_geometry_pnr.adf') 'text')+')'+
          ' (_option force_to_run (_switch ON)) (_option delay_type (_string "min_max")) (_option max_path (_integer 10)) (_option report_exception (_switch ON)))'
    }elseif($Stage -eq 'sbit'){
        $cmd='(_command cmd_gen_bitstream (_option input_db_file '+(FileNode (Join-Path $runDir 'routed_snapshot/mini_raw8_geometry_pnr.adf') 'text')+')'+
          ' (_option force_to_run (_switch ON)) (_option scbv (_string "High Voltage")))'
    }
    return '(_flow synthetic (_comment "NOT NATIVE EVIDENCE") (_part (_family Logos2) (_device PG2L100H) (_speedgrade -6) (_package FBG676)) (_input '+($files -join ' ')+') '+$cmd+')'
}
foreach($stage in $state.stages){Put (Join-Path $runDir ('geometry_priority_'+$stage+'.pds')) (MakeProject $stage)}
$pnrProject=Join-Path $runDir 'geometry_priority_pnr.pds'
$pnrLog=Join-Path $runDir 'pnr.log'
Put $pnrLog ("Analyzing project file '"+$pnrProject.Replace('\','/')+"'.`nRcf routing step 1 processed 11 nets, it takes 0.06 sec.`n")
$auditPath=Join-Path $runDir 'priority_override.json'; $hashPath=Join-Path $runDir 'checkpoint_hashes.json'
function Seal {
    # Only fixture authors may refresh hashes; negative tests use this to
    # ensure validation rejects semantic substitution, not just stale SHA.
    $state.bindings=@(Get-PriorityBindings $state)
    $state.native_priority_route=Get-PriorityRouteProof $runDir
    Json $auditPath $state
    Json $hashPath @($state.bindings | ForEach-Object {[pscustomobject]@{Algorithm='SHA256';Hash=$_.sha256;Path=$_.path}})
}
Seal
$baseline=@{}
Get-ChildItem -LiteralPath $fixtureFpga -File -Recurse | ForEach-Object {$baseline[$_.FullName]=[IO.File]::ReadAllBytes($_.FullName)}
$baselineState=$state | ConvertTo-Json -Depth 20
function Restore {
    # Recover known fixture files only; never delete recursively or touch a
    # sibling task's files. Extra files from attacks are harmless unless loaded.
    foreach($p in $baseline.Keys){[IO.File]::WriteAllBytes($p,$baseline[$p])}
    $script:state=$baselineState | ConvertFrom-Json
}
function Resign {
    # Refresh existing bindings WITHOUT policy helpers, so the negative test
    # reaches actual gate validation of a malicious-but-self-consistent record.
    foreach($e in $state.bindings){$e.sha256=Get-PriorityHash $e.path}
    if($null -ne $state.native_priority_route){$state.native_priority_route.sha256=Get-PriorityHash $pnrLog}
    Json $auditPath $state
    Json $hashPath @($state.bindings | ForEach-Object {[pscustomobject]@{Algorithm='SHA256';Hash=$_.sha256;Path=$_.path}})
}
function Case([string]$Name,[scriptblock]$Action,[bool]$Pass=$false,[string]$Expected='') {
    Restore
    $errorText=''
    try {& $Action; $answer=& $checker -Run $runDir; Need ($answer.passed -is [bool] -and $answer.passed) 'Missing success object'}
    catch {$errorText=$_.Exception.Message}
    $ok=if($Pass){!$errorText}else{[bool]$errorText -and (!$Expected -or $errorText -match $Expected)}
    $results.Add([pscustomobject]@{name=$Name;passed=$ok;expected_pass=$Pass;diagnostic=$errorText})
    if(!$ok){throw "$Name unexpected result: $errorText"}
}
try {
    Case 'seed_zero_all_stages_and_plc_binding' {} $true
    Case 'tcl_actual_source_dispatch_with_native_commands_stubbed' {
        # Evaluate the real Tcl in Tcl 8.6 with inert command callbacks. This
        # checks both seed branches and all stages without starting PDS/PNR.
        $code=@'
import tkinter, sys, json
script, run, cp = sys.argv[1:]
checks = 0
for seed in (0, 5):
 for stage in ('configure', 'pnr', 'sta', 'sbit'):
  t = tkinter.Tcl(); calls = []
  for name in ('set_arch','set_dir','add_constraint','pnr','report_timing','gen_bit_stream'):
   def record(*args, name=name):
    calls.append((name, args)); return ''
   t.createcommand(name, record)
  env = dict(GEOMETRY_PRIORITY_RUN=run, GEOMETRY_PRIORITY_STAGE=stage,
   GEOMETRY_MAP_PCF=cp+'/mini_raw8_geometry.pcf', GEOMETRY_MAP_DB=cp+'/mini_raw8_geometry_map.adf',
   GEOMETRY_PLACE_DB=cp+'/mini_raw8_geometry_plc.adf', GEOMETRY_NEW_SEED=str(seed),
   GEOMETRY_DECONGESTION='6', GEOMETRY_PNR_DB=run+'/routed_snapshot/mini_raw8_geometry_pnr.adf')
  for k,v in env.items(): t.setvar('env('+k+')',v)
  t.call('source',script)
  constraints=[a[0].replace('\\','/') for n,a in calls if n=='add_constraint']
  assert len(constraints)==10 and len(set(constraints))==10
  assert [p for p in constraints if p.endswith('.rcf')]==[run.replace('\\','/')+'/routing/geometry_priority.rcf']
  active=[(n,a) for n,a in calls if n in ('pnr','report_timing','gen_bit_stream')]
  if stage=='configure': assert not active
  else:
   assert len(active)==1
   n,a=active[0]
   assert n==dict(pnr='pnr',sta='report_timing',sbit='gen_bit_stream')[stage]
   if stage=='pnr':
    assert ('-input_place_db_file' in a)==(seed==0)
    assert a[a.index('-gplace_seed')+1]==str(2 if seed==0 else seed)
    assert a[a.index('-plc_decongestion')+1]=='6'
    assert all(x in a for x in ('-fix_hold_violation','-optimize_multi_corner_timing','-report_timing'))
   elif stage=='sta': assert a[a.index('-delay_type')+1]=='min_max'
  checks+=1
print(json.dumps(dict(mock_only=True,native_tools_run=False,checks=checks)))
'@
        $out=@($code | & python -X utf8 - (Join-Path $fixtureFpga 'scripts/resume_geometry_priority_route.tcl') $runDir $cp)
        Need ($LASTEXITCODE -eq 0) 'Tcl mock interpreter failed'
        $summary=$out[-1] | ConvertFrom-Json
        Need ($summary.checks -eq 8 -and $summary.mock_only -and !$summary.native_tools_run) 'Tcl stage coverage missing'
    } $true
    Case 'audit_path_public_interface' {$answer=& $checker -Audit $auditPath; Need $answer.passed 'Audit API failed'} $true
    Case 'positive_seed_excludes_plc' {
        $state.new_placement_seed=5; Put $pnrProject (MakeProject pnr 5); Seal
        Need (@($state.bindings | Where-Object role -eq 'placed_db').Count -eq 0) 'PLC bound for positive seed'
    } $true
    Case 'configure_only_not_exporter_proof' {
        $state.stages=@('configure'); Seal
        $internal=Assert-PriorityAudit $auditPath
        Need ($internal.passed -and !$internal.native_priority_route_verified) 'Internal configure preflight failed'
    } $false 'Public gate requires'
    Case 'missing_inherited_net' {Put $candidate ($allCommands[1..10] -join "`n"); Put $frozen ([IO.File]::ReadAllText($candidate)); Resign} $false 'Missing'
    Case 'duplicate_net' {Put $candidate (($allCommands+@($allCommands[0])) -join "`n"); Resign} $false 'Duplicate'
    Case 'unknown_net' {Put $candidate (($allCommands -join "`n").Replace('adj_wrdq [22]','adj_wrdq [23]')); Resign} $false 'Unreviewed'
    Case 'unknown_command' {Put $candidate (([IO.File]::ReadAllText($candidate))+"`nset_false_path -from all"); Resign} $false 'Unknown RCF'
    Case 'wrapper_rejects_before_native_launch' {
        Put $candidate 'set_false_path -from all'
        & (Join-Path $fixtureFpga 'scripts/resume_geometry_priority_route.ps1') -Checkpoint $cp -NewPlacementSeed 0 -PriorityRcf $candidate -PdsHome (Join-Path $testRun 'NO_NATIVE_RUNTIME')
    } $false 'Unknown RCF'
    Case 'semicolon_command_injection' {Put $candidate (([IO.File]::ReadAllText($candidate))+'; puts bypass'); Resign} $false 'Unknown RCF'
    Case 'case_alias_net' {Put $candidate (([IO.File]::ReadAllText($candidate)).Replace('debug_data','DEBUG_DATA')); Resign} $false 'Unreviewed'
    Case 'two_native_rcfs' {Put $pnrProject ((MakeProject pnr).Replace('(_input ','(_input '+(FileNode $candidate 'rcf')+' ')); Resign} $false 'Native constraint'
    Case 'duplicate_same_native_rcf' {Put $pnrProject ((MakeProject pnr).Replace('(_input ','(_input '+(FileNode $frozen 'rcf')+' ')); Resign} $false 'Native constraint'
    Case 'same_basename_wrong_actual_rcf' {
        $other=Join-Path $runDir 'decoy/geometry_priority.rcf'; Put $other ([IO.File]::ReadAllText($frozen))
        Put $pnrProject ((MakeProject pnr).Replace($frozen.Replace('\','/'),$other.Replace('\','/'))); Resign
    } $false 'Native constraint'
    Case 'missing_native_rcf_comment_spoof' {
        $text=(MakeProject pnr).Replace((FileNode $frozen 'rcf'),'')
        $text=$text.Replace('NOT NATIVE EVIDENCE','fake (_file geometry_priority.rcf (_format rcf))')
        Put $pnrProject $text; Resign
    } $false 'Native constraint'
    Case 'extra_fdc' {Put $pnrProject ((MakeProject pnr).Replace('(_input ','(_input '+(FileNode $originalRcf 'fdc')+' ')); Resign} $false 'format mismatch'
    Case 'unknown_constraint_format' {Put $pnrProject ((MakeProject pnr).Replace('(_format rcf)','(_format text)')); Resign} $false 'format mismatch'
    Case 'wrong_architecture' {Put $pnrProject ((MakeProject pnr).Replace('PG2L100H','PG2L200H')); Resign} $false 'target part'
    Case 'wrong_map_path' {Put $pnrProject ((MakeProject pnr).Replace((FileNode $map 'text'),(FileNode $originalMap 'text'))); Resign} $false 'DB path'
    Case 'missing_seed_zero_plc' {Put $pnrProject (MakeProject pnr 2); Resign} $false 'Seed zero'
    Case 'disabled_hold_repair' {Put $pnrProject ((MakeProject pnr).Replace('fix_hold_violation (_switch ON)','fix_hold_violation (_switch OFF)')); Resign} $false 'option mismatch'
    Case 'wrong_decongestion' {Put $pnrProject ((MakeProject pnr).Replace('plc_decongestion (_integer 6)','plc_decongestion (_integer 3)')); Resign} $false 'option mismatch'
    Case 'unapproved_native_option' {Put $pnrProject ((MakeProject pnr).Replace('(_command cmd_pnr','(_command cmd_pnr (_option ignore_timing (_switch ON))')); Resign} $false 'Unapproved native option'
    Case 'sta_max_only' {$p=Join-Path $runDir 'geometry_priority_sta.pds'; Put $p ((MakeProject sta).Replace('min_max','max')); Resign} $false 'option mismatch'
    foreach($property in @('override_only','source_inputs_unchanged','timing_budget_changed','release_qualified')){
        Case ('string_boolean_'+$property) {$state.$property=[string]$state.$property; Json $auditPath $state}.GetNewClosure() $false 'Strict boolean'
    }
    Case 'string_seed' {$state.new_placement_seed='0'; Json $auditPath $state} $false 'Invalid native controls'
    Case 'comparison_string_false' {$c=Read-PriorityJson $cmpPath; $c.timing_budget_changed='false'; Json $cmpPath $c; Resign} $false 'Strict boolean'
    Case 'comparison_path_substitution' {$c=Read-PriorityJson $cmpPath; $c.copied_pcf=$originalPcf; Json $cmpPath $c; Resign} $false 'PCF path'
    Case 'candidate_frozen_self_attestation' {$state.candidate_rcf=$frozen; Json $auditPath $state} $false 'self-attest'
    Case 'run_identity_substitution' {$state.run=$cp; Json $auditPath $state} $false 'identity'
    Case 'missing_hash_binding' {$state.bindings=@($state.bindings | Where-Object role -ne 'checker'); Json $auditPath $state} $false 'Incomplete'
    Case 'duplicate_hash_role' {$state.bindings[0]=$state.bindings[1]; Json $auditPath $state} $false 'binding'
    Case 'checkpoint_hash_omission' {Json $hashPath @((Read-PriorityJson $hashPath) | Select-Object -Skip 1)} $false 'Incomplete'
    foreach($pair in @(@('candidate',$candidate),@('frozen',$frozen),@('original_rcf',$originalRcf),@('checker',$checker),
      @('wrapper',(Join-Path $fixtureFpga 'scripts/resume_geometry_priority_route.ps1')),
      @('tcl',(Join-Path $fixtureFpga 'scripts/resume_geometry_priority_route.tcl')),
      @('native_project',$pnrProject),@('plc',$plc),@('map',$map),@('origin_map',$originalMap),@('rtl_source',$rtl),
      @('origin_manifest',(Join-Path $origin 'source_manifest.json')))){
        Case ('hash_drift_'+$pair[0]) {Put $pair[1] (([IO.File]::ReadAllText($pair[1]))+"`n# drift")}.GetNewClosure() $false
    }
    Case 'native_log_only_eight_nets' {Put $pnrLog ([IO.File]::ReadAllText($pnrLog).Replace('11 nets','8 nets')); Resign} $false '11 nets'
    Case 'native_log_missing_count' {Put $pnrLog 'SYNTHETIC no priority report'; Resign} $false '11 nets'
    Case 'native_log_duplicate_count' {Put $pnrLog ([IO.File]::ReadAllText($pnrLog)+"Rcf routing step 1 processed 11 nets`n"); Resign} $false '11 nets'
    Case 'native_log_unknown_net' {Put $pnrLog ([IO.File]::ReadAllText($pnrLog)+"W: Unknown net debug_data`n"); Resign} $false 'unknown/unmatched'
    Case 'native_log_no_match' {Put $pnrLog ([IO.File]::ReadAllText($pnrLog)+"W: RCF matches no nets`n"); Resign} $false 'unknown/unmatched'
    Case 'native_log_ignored_rcf' {Put $pnrLog ([IO.File]::ReadAllText($pnrLog)+"W: def_route priority ignored`n"); Resign} $false 'ignored'
    Case 'native_log_wrong_project' {Put $pnrLog ([IO.File]::ReadAllText($pnrLog).Replace('geometry_priority_pnr.pds','geometry_priority_sta.pds')); Resign} $false 'project substitution'
    Case 'proof_string_count' {$state.native_priority_route.match_count='1'; Json $auditPath $state} $false 'proof mismatch'
    Case 'proof_hash_drift' {$state.native_priority_route.sha256=('0'*64); Json $auditPath $state} $false 'proof mismatch'
    Case 'known_hdmi_precedence_warning' {
        Put $pnrLog ([IO.File]::ReadAllText($pnrLog)+"W: PhysicalConstraintEditor-4048: [board.pcf(line number: 127)] Repeat constraints on u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv is found, the def_inst_site command have higher priority or the instance has already done def_inst_region constraint, so that the def_inst_region command is ignored.`n"); Resign
    } $true
    Case 'extra_ddr_leaf_even_resigned' {
        $delta=$pcfText+"`ndef_inst_site {I_ips_ddr_top/new_ddr_leaf} CLMA_1_1 FF0"
        Put $pcf $delta; Put $originalPcf $delta
        $c=Read-PriorityJson $cmpPath; $c.sha256=Get-PriorityHash $pcf; Json $cmpPath $c
        $o=Read-PriorityJson $originAudit; $o.inputs[0].sha256=Get-PriorityHash $originalPcf; Json $originAudit $o; Resign
    } $false 'DDR leaf'
    Case 'malformed_native_parentheses' {Put $pnrProject ((MakeProject pnr)+')'); Resign} $false 'nesting'
    Case 'ddr_region_delta_even_resigned' {
        $delta=$pcfText+"`ndef_region ddr_extra 1 2 3 4 {CLMA CLMS}"
        Put $pcf $delta; Put $originalPcf $delta
        $c=Read-PriorityJson $cmpPath; $c.sha256=Get-PriorityHash $pcf; Json $cmpPath $c
        $o=Read-PriorityJson $originAudit; $o.inputs[0].sha256=Get-PriorityHash $originalPcf; Json $originAudit $o; Resign
    } $false 'PCF command/region'
    # Last mutation creates a forbidden file without deleting it later. The
    # entire synthetic directory is retained as honest regression evidence.
    Case 'ddr_delta_audit_present' {Put (Join-Path $cp 'ddr_placement_audit.json') '{}'} $false 'DDR delta'
} finally {
    Json (Join-Path $testRun 'test_results.json') ([ordered]@{synthetic_only=$true;native_tools_run=$false;
      powershell_version=$PSVersionTable.PSVersion.ToString();passed=(@($results | Where-Object {!$_.passed}).Count -eq 0);
      count=$results.Count;cases=@($results.ToArray())})
}
Write-Output "GEOMETRY_PRIORITY_OVERRIDE_TESTS_PASS count=$($results.Count) $testRun"
