# Purpose: fail-closed physical-input gate for the priority-only runner.
# Exporter API: & ./check_geometry_priority_override.ps1 -Run <run-directory>
# or -Audit <run/priority_override.json>. Throws on failure; emits one object
# on success. This is provenance validation, NEVER a timing/release approval.
# Dot-sourcing exposes the same helpers to the runner and offline fixtures.
[CmdletBinding()]
param([string]$Audit='', [string]$Run='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:PriorityCheckerPath=$PSCommandPath
$script:PriorityFpga=Split-Path $PSScriptRoot -Parent

function Get-PriorityPath([string]$Path,[string]$Base='') {
    # Resolve actual filesystem identity; refuse junction/symlink ancestors so
    # a build-prefix spelling cannot redirect evidence outside the project.
    if(!$Path){throw 'Empty evidence path'}
    if(![IO.Path]::IsPathRooted($Path)){
        if(!$Base){throw "Absolute path required: $Path"}
        $Path=Join-Path $Base $Path
    }
    $full=[IO.Path]::GetFullPath($Path)
    if(!(Test-Path -LiteralPath $full)){throw "Missing evidence: $full"}
    $item=Get-Item -LiteralPath $full -Force
    $node=$item
    while($null -ne $node){
        if(($node.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse evidence path rejected'}
        $node=if($node -is [IO.DirectoryInfo]){$node.Parent}else{$node.Directory}
    }
    return $item.FullName.TrimEnd('\','/')
}
function Assert-PriorityInside([string]$Path,[string]$Root) {
    $p=Get-PriorityPath $Path; $r=Get-PriorityPath $Root
    if(!$p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Outside required directory: $p"}
    return $p
}
function Get-PriorityHash([string]$Path) {
    $p=Get-PriorityPath $Path
    if((Get-Item -LiteralPath $p).PSIsContainer -or (Get-Item -LiteralPath $p).Length -eq 0){throw 'Empty/non-file evidence'}
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
}
function Read-PriorityJson([string]$Path) {
    # PS5.1 emits a top-level JSON array as one pipeline object; PS7 unrolls
    # it. Explicit enumeration keeps all callers' @(...).Count identical.
    $value=[IO.File]::ReadAllText((Get-PriorityPath $Path)) | ConvertFrom-Json
    if($value -is [array]){foreach($item in $value){Write-Output $item}}else{Write-Output $value}
}
function Assert-PriorityBool($Value,[bool]$Expected,[string]$Label) {
    if($Value -isnot [bool] -or $Value -ne $Expected){throw "Strict boolean required: $Label"}
}
function Test-PriorityInteger($Value) {
    # ConvertFrom-Json uses Int32 on Windows PS5.1 and Int64 on PS7.
    return ($Value -is [int] -or $Value -is [long])
}
function Get-PriorityFdc {
    # Exact existing runner budget set; no user-supplied alternate FDC path.
    return @('constraints/mini_camera_diag/ddr_native.fdc','constraints/ddr_board_pins.fdc',
      'constraints/mini_raw8_dual/geometry_pins.fdc','constraints/mini_raw8_dual/timing.fdc',
      'constraints/mini_raw8_dual/cdc.fdc','constraints/mini_raw8_dual/geometry_view_cdc.fdc',
      'constraints/placement.fdc','constraints/mini_raw8_dual/geometry_reset_sites.fdc')
}
function Get-PriorityNets {
    # Eight inherited nets and ONLY the three reviewed Run18 additions.
    $slice='I_ips_ddr_top/u_ddrphy_top/ddrphy_slice_top/i_dqs_group[1].ddrphy_data_slice/'
    return @('I_ips_ddr_top/u_ddrphy_top/ddrphy_ioclk_gate [0]',
      'I_ips_ddr_top/u_ddrphy_top/ddrphy_ioclk_gate [1]',
      'u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset',
      'u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset',
      'u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset','u_hdmi_tx/u_clock_lane/lane_reset',
      'I_ips_ddr_top/u_ddrphy_top/phy_wrdata_en [0]',($slice+'adj_wrdq_en [5]'),
      ($slice+'adj_wrdq [22]'),($slice+'adj_wrdq [60]'),($slice+'debug_data [67]'))
}
function Assert-PriorityRcf([string]$Path,[int]$Count=11) {
    # Deliberately tiny language: one literal command per line, no Tcl eval,
    # semicolons, continuations, substitutions, wildcards or inline commands.
    $expected=@(Get-PriorityNets)[0..($Count-1)]; $seen=@{}
    foreach($line in [IO.File]::ReadAllLines((Get-PriorityPath $Path))){
        $s=$line.Trim(); if(!$s -or $s.StartsWith('#')){continue}
        if($s -cnotmatch '^def_route -prior_net \{([^{}]+)\}$'){throw 'Unknown RCF command'}
        $net=$Matches[1]
        if($seen.ContainsKey($net)){throw 'Duplicate RCF net'}
        if($expected -cnotcontains $net){throw 'Unreviewed RCF net'}
        $seen[$net]=$true
    }
    if($seen.Count -ne $Count){throw 'Missing original/reviewed RCF command'}
}
function Assert-PrioritySources([string]$Manifest) {
    # Rehash every original mapping source, reject empty/duplicate manifests.
    $entries=@(Read-PriorityJson $Manifest); if(!$entries.Count){throw 'Empty source manifest'}
    $seen=@{}
    foreach($entry in $entries){
        $p=Assert-PriorityInside $entry.path $script:PriorityFpga
        if($seen.ContainsKey($p)){throw 'Duplicate source manifest path'}
        $seen[$p]=$true
        if($entry.sha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-PriorityHash $p) -ine $entry.sha256){throw "Source hash drift: $p"}
    }
    return $entries
}
function Get-PriorityCheckpoint([string]$Checkpoint,[int]$Seed) {
    # Native-free provenance is the unchanged board PCF and original map,
    # NOT a directory name or the legacy default ddr_profile=ten label.
    $cp=Assert-PriorityInside $Checkpoint (Join-Path $script:PriorityFpga 'build')
    if(Test-Path -LiteralPath (Join-Path $cp 'ddr_placement_audit.json')){throw 'DDR delta checkpoint rejected'}
    $cmp=Read-PriorityJson (Join-Path $cp 'comparison.json')
    Assert-PriorityBool $cmp.timing_budget_changed $false 'comparison timing_budget_changed'
    $pcf=Get-PriorityPath (Join-Path $cp 'mini_raw8_geometry.pcf')
    if((Get-PriorityPath $cmp.copied_pcf) -ine $pcf){throw 'Comparison PCF path substitution'}
    $original=Assert-PriorityInside $cmp.original_pcf (Join-Path $script:PriorityFpga 'build')
    if($original -ieq $pcf){throw 'Original PCF cannot self-attest'}
    $originDir=Split-Path $original -Parent
    $originAudit=Join-Path $originDir 'ddr_placement_audit.json'
    $oa=Read-PriorityJson $originAudit
    Assert-PriorityBool $oa.source_inputs_unchanged $true 'origin source_inputs_unchanged'
    $map=Get-PriorityPath (Join-Path $cp 'mini_raw8_geometry_map.adf')
    $originMap=Get-PriorityPath (Join-Path $originDir 'mini_raw8_geometry_map.adf')
    $originManifest=Get-PriorityPath (Join-Path $originDir 'source_manifest.json')
    $manifest=Get-PriorityPath (Join-Path $cp 'source_manifest.json')
    foreach($p in @($original,$originMap)){
        $rows=@($oa.inputs | Where-Object {(Get-PriorityPath $_.path) -ieq $p})
        if($rows.Count -ne 1 -or (Get-PriorityHash $p) -ine $rows[0].sha256){throw 'Original map/PCF provenance drift'}
    }
    if($cmp.sha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-PriorityHash $pcf) -ine $cmp.sha256 -or
       (Get-PriorityHash $original) -ine $cmp.sha256){throw 'Native-free PCF differs from original'}
    if((Get-PriorityHash $map) -ine (Get-PriorityHash $originMap)){throw 'Map differs from original mapping'}
    if((Get-PriorityHash $manifest) -ine (Get-PriorityHash $originManifest)){throw 'Original source manifest changed'}
    # Only the seven native clock/reset/CPD sites are legal; no DDR data leaf
    # can sneak in even if a comparison JSON is regenerated around a delta.
    $sites=@(
      'def_inst_site {I_ips_ddr_top/u_ddrphy_top/ddrphy_reset_ctrl/ddrphy_ioclk_gate[0]/opit_0_inv} CLMA_357_354 FF3',
      'def_inst_site {I_ips_ddr_top/u_ddrphy_top/ddrphy_reset_ctrl/ddrphy_ioclk_gate[1]/opit_0_inv} CLMA_357_660 FF3',
      'def_inst_site {I_ips_ddr_top/u_ddrphy_top/u_ddrphy_cpd/cpd_inst} DDRPHY_CPD_369_466',
      'def_inst_site {u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv} CLMA_21_378 FF0',
      'def_inst_site {u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset/opit_0_inv} CLMA_21_402 FF0',
      'def_inst_site {u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset/opit_0_inv} CLMA_21_426 FF0',
      'def_inst_site {u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv} CLMA_21_450 FF0')
    $actual=@([IO.File]::ReadAllLines($pcf) | Where-Object {$_ -match '^\s*def_inst_site\b'} | ForEach-Object {$_.Trim()})
    if($actual.Count -ne 7 -or @(Compare-Object $sites $actual -CaseSensitive).Count){throw 'DDR leaf/site delta rejected'}
    # Also refuse region/attribute forms of a DDR delta, not just extra sites.
    $regions=@('def_region hdmi_reset_ck 3 4 73 75 {CLMA CLMS}',
      'def_region hdmi_reset_d0 3 4 61 63 {CLMA CLMS}',
      'def_region hdmi_reset_d1 3 4 65 67 {CLMA CLMS}',
      'def_region hdmi_reset_d2 3 4 69 71 {CLMA CLMS}',
      'def_inst_region {u_hdmi_tx/g_data_lanes[0].u_data_lane/lane_reset/opit_0_inv} hdmi_reset_d0',
      'def_inst_region {u_hdmi_tx/g_data_lanes[1].u_data_lane/lane_reset/opit_0_inv} hdmi_reset_d1',
      'def_inst_region {u_hdmi_tx/g_data_lanes[2].u_data_lane/lane_reset/opit_0_inv} hdmi_reset_d2',
      'def_inst_region {u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv} hdmi_reset_ck')
    $ports=@{}; $other=@()
    foreach($line in [IO.File]::ReadAllLines($pcf)){
        $s=$line.Trim(); if(!$s -or $s.StartsWith('#')){continue}
        if($s -cmatch '^def_port \{([^{}]+)\} [^;{}]+$'){
            if($ports.ContainsKey($Matches[1])){throw 'Duplicate native board port'}
            $ports[$Matches[1]]=$true
        }elseif($sites -ccontains $s){continue}else{$other+=@($s)}
    }
    if($ports.Count -ne 113 -or $other.Count -ne 8 -or @(Compare-Object $regions $other -CaseSensitive).Count){throw 'Native PCF command/region delta rejected'}
    $sources=@(Assert-PrioritySources $manifest)
    foreach($rel in @('constraints/mini_raw8_dual/geometry_priority.rcf')+@(Get-PriorityFdc)){
        $p=Get-PriorityPath (Join-Path $script:PriorityFpga $rel)
        if(@($sources | Where-Object {(Get-PriorityPath $_.path) -ieq $p}).Count -ne 1){throw 'Mapping manifest lacks original constraint'}
    }
    $plc=''; if($Seed -eq 0){$plc=Get-PriorityPath (Join-Path $cp 'mini_raw8_geometry_plc.adf'); $null=Get-PriorityHash $plc}
    return [pscustomobject]@{checkpoint=$cp;pcf=$pcf;map=$map;manifest=$manifest;plc=$plc;
      original_pcf=$original;original_map=$originMap;original_manifest=$originManifest;origin_audit=$originAudit}
}
function Get-PriorityNodeBlocks([string]$Text,[string]$Name) {
    # Small balanced S-expression reader for actual native .pds nodes. Quoted
    # strings (including _comment text) cannot inject fake _file/_option nodes.
    $mask=$Text.ToCharArray(); $quoted=$false; $escape=$false
    for($i=0;$i -lt $mask.Length;$i++){
        $c=$Text[$i]
        if($quoted){$mask[$i]=' '; if($escape){$escape=$false}elseif($c -eq '\'){$escape=$true}elseif($c -eq '"'){$quoted=$false}}
        elseif($c -eq '"'){$quoted=$true; $mask[$i]=' '}
    }
    if($quoted){throw 'Malformed native quoted string'}
    $masked=-join $mask; $depth=0
    foreach($c in $mask){if($c -eq '('){$depth++}elseif($c -eq ')'){$depth--; if($depth -lt 0){throw 'Malformed native nesting'}}}
    if($depth){throw 'Malformed native nesting'}
    foreach($m in [regex]::Matches($masked,'\('+[regex]::Escape($Name)+'(?=\s|\))')){
        $d=0; $end=$m.Index
        for($j=$m.Index;$j -lt $mask.Length;$j++){
            if($mask[$j] -eq '('){$d++}elseif($mask[$j] -eq ')'){$d--; if(!$d){$end=$j; break}}
        }
        $Text.Substring($m.Index,$end-$m.Index+1)
    }
}
function Assert-PriorityProject([string]$Project,$State,[string]$Stage) {
    # Read native-selected files, not filename mentions. Require the complete
    # same FDC set, exact original PCF, one exact frozen RCF, and target part.
    $text=[IO.File]::ReadAllText((Get-PriorityPath $Project)); $dir=Split-Path $Project -Parent
    foreach($pair in @(@('_family','Logos2'),@('_device','PG2L100H'),@('_speedgrade','-6'),@('_package','FBG676'))){
        $n=@(Get-PriorityNodeBlocks $text $pair[0]); if($n.Count -ne 1 -or $n[0] -cnotmatch ('^\('+[regex]::Escape($pair[0])+'\s+'+[regex]::Escape($pair[1])+'\s*\)$')){throw 'Native target part mismatch'}
    }
    $constraints=@(); $files=@(Get-PriorityNodeBlocks $text '_file')
    foreach($node in $files){
        if($node -notmatch '^\(_file\s+"([^"\r\n]+)"'){throw 'Malformed native file node'}
        $name=$Matches[1]; $formats=@(Get-PriorityNodeBlocks $node '_format')
        if($formats.Count -ne 1 -or $formats[0] -notmatch '^\(_format\s+(\w+)\s*\)$'){throw 'Malformed native file format'}
        $format=$Matches[1]
        if($format -in @('fdc','rcf','pcf','sdc') -or [IO.Path]::GetExtension($name) -in @('.fdc','.rcf','.pcf','.sdc')){
            if($format -notin @('fdc','rcf','pcf') -or [IO.Path]::GetExtension($name) -ine ('.'+$format)){throw 'Native constraint format mismatch'}
            $constraints+=Get-PriorityPath $name $dir
        }
    }
    $expected=@(Get-PriorityFdc | ForEach-Object {Get-PriorityPath (Join-Path $script:PriorityFpga $_)})+
      @((Get-PriorityPath (Join-Path $State.run 'routing/geometry_priority.rcf')),(Get-PriorityPath (Join-Path $State.checkpoint 'mini_raw8_geometry.pcf')))
    if($constraints.Count -ne $expected.Count -or @($constraints | Select-Object -Unique).Count -ne $expected.Count -or
       @(Compare-Object $expected $constraints).Count){throw 'Native constraint set/unique actual RCF path mismatch'}
    # Verify the command's bound database and optimization options. Configure
    # contains no implementation command; later stages each contain one.
    $commands=@(Get-PriorityNodeBlocks $text '_command')
    $active=@($commands | Where-Object {$_ -match '^\(_command\s+cmd_(pnr|report_post_pnr_timing|gen_bitstream)\b' -and $_ -match '\(_option\s+input_db_file\b'})
    if($Stage -eq 'configure'){if($active.Count){throw 'Configure unexpectedly runs implementation'}; return}
    $commandName=@{pnr='cmd_pnr';sta='cmd_report_post_pnr_timing';sbit='cmd_gen_bitstream'}[$Stage]
    if($active.Count -ne 1 -or $active[0] -notmatch ('^\(_command\s+'+$commandName+'\b')){throw 'Native stage command mismatch'}
    $cmd=$active[0]; $options=@{}
    foreach($opt in @(Get-PriorityNodeBlocks $cmd '_option')){
        if($opt -notmatch '^\(_option\s+(\w+)\b'){throw 'Malformed native option'}
        $key=$Matches[1]; if($options.ContainsKey($key)){throw 'Duplicate native option'}; $options[$key]=$opt
    }
    $db=if($Stage -eq 'pnr'){Join-Path $State.checkpoint 'mini_raw8_geometry_map.adf'}else{Join-Path $State.run 'routed_snapshot/mini_raw8_geometry_pnr.adf'}
    foreach($key in @('input_db_file')){
        if(!$options.ContainsKey($key) -or $options[$key] -notmatch '\(_file\s+"([^"\r\n]+)"'){throw 'Native DB missing'}
        if((Get-PriorityPath $Matches[1] $dir) -ine (Get-PriorityPath $db)){throw 'Native DB path substitution'}
    }
    if($Stage -eq 'pnr'){
        if($State.new_placement_seed -eq 0){
            if(!$options.ContainsKey('input_place_db_file') -or $options.input_place_db_file -notmatch '\(_file\s+"([^"\r\n]+)"'){throw 'Seed zero needs PLC'}
            if((Get-PriorityPath $Matches[1] $dir) -ine (Get-PriorityPath (Join-Path $State.checkpoint 'mini_raw8_geometry_plc.adf'))){throw 'PLC path substitution'}
        }elseif($options.ContainsKey('input_place_db_file')){throw 'Positive seed must not reuse PLC'}
        $seed=if($State.new_placement_seed -eq 0){2}else{$State.new_placement_seed}
        $required=@{action_timeout='180';congest_overlap_limit='20';gplace_seed=[string]$seed;plc_decongestion=[string]$State.decongestion;mode='performance';optimize_multi_corner_timing='ON';fix_hold_violation='ON';fix_hold_violation_iterations='10';report_timing='ON';force_to_run='ON'}
    }elseif($Stage -eq 'sta'){$required=@{force_to_run='ON';delay_type='min_max';max_path='10';report_exception='ON'}}
    else{$required=@{force_to_run='ON';scbv='High Voltage'}}
    foreach($key in $required.Keys){
        if(!$options.ContainsKey($key) -or $options[$key] -notmatch ('\(_(?:integer|string|switch)\s+"?'+[regex]::Escape($required[$key])+'"?\s*\)')){throw "Native required option mismatch: $key"}
    }
    $allowed=@($required.Keys)+@('input_db_file')
    if($Stage -eq 'pnr' -and $State.new_placement_seed -eq 0){$allowed+=@('input_place_db_file')}
    foreach($key in $options.Keys){if($allowed -notcontains $key){throw "Unapproved native option: $key"}}
}
function Get-PriorityBindings($State) {
    # Compute expected roles from trusted paths/policy, never trust a manifest
    # that can omit the checker, original map, original RCF or actual project.
    $cp=Get-PriorityCheckpoint $State.checkpoint $State.new_placement_seed
    $roles=[ordered]@{original_rcf=(Join-Path $script:PriorityFpga 'constraints/mini_raw8_dual/geometry_priority.rcf');
      candidate_rcf=$State.candidate_rcf;frozen_rcf=(Join-Path $State.run 'routing/geometry_priority.rcf');
      checker=$script:PriorityCheckerPath;wrapper=(Join-Path $script:PriorityFpga 'scripts/resume_geometry_priority_route.ps1');
      tcl=(Join-Path $script:PriorityFpga 'scripts/resume_geometry_priority_route.tcl');
      comparison=(Join-Path $cp.checkpoint 'comparison.json');map_db=$cp.map;map_pcf=$cp.pcf;
      source_manifest=$cp.manifest;run_source_manifest=(Join-Path $State.run 'source_manifest.json');
      original_pcf=$cp.original_pcf;original_map=$cp.original_map;original_manifest=$cp.original_manifest;origin_audit=$cp.origin_audit}
    if($State.new_placement_seed -eq 0){$roles.placed_db=$cp.plc}
    $i=0; foreach($rel in @(Get-PriorityFdc)){$roles[('fdc_'+$i)]=Join-Path $script:PriorityFpga $rel; $i++}
    foreach($stage in @($State.stages)){$roles[('native_'+$stage)]=Join-Path $State.run ('geometry_priority_'+$stage+'.pds')}
    if(@($State.stages) -contains 'pnr'){
        $roles.routed_db=Join-Path $State.run 'routed_snapshot/mini_raw8_geometry_pnr.adf'
        $roles.priority_route_log=Join-Path $State.run 'pnr.log'
    }
    foreach($key in $roles.Keys){[pscustomobject]@{role=$key;path=(Get-PriorityPath $roles[$key]);sha256=(Get-PriorityHash $roles[$key])}}
}
function Assert-PriorityNativeDiagnostics([string]$Log) {
    # Fail unknown/unmatched names and ignored constraints. The ONLY ignored
    # warning allowed is the pre-existing four HDMI region/site precedence
    # notices, not any RCF route/net diagnostic or other ignored command.
    foreach($line in [IO.File]::ReadAllLines((Get-PriorityPath $Log))){
        if($line -match '(?i)^\s*E:|STA-301[35]|cannot find|matches no|no matching|unknown (?:net|instance|constraint)|unmatched|No .* found|(?:net|instance|constraint).*?(?:not found|does not exist|not exist|no match|unresolved)'){throw 'Native unknown/unmatched/error diagnostic'}
        if($line -match '(?i)ignor(?:ed|ing)'){
            $known=$line -match '^W: PhysicalConstraintEditor-4048:' -and $line -match '\.pcf\(line number: \d+\)' -and
              $line -match 'Repeat constraints on u_hdmi_tx/(?:g_data_lanes\[[012]\]\.u_data_lane|u_clock_lane)/lane_reset/opit_0_inv is found,' -and
              $line.EndsWith('the def_inst_region command is ignored.') -and $line -notmatch '(?i)\brcf\b|def_route|prior_net'
            if(!$known){throw 'Native ignored constraint/net diagnostic'}
        }
    }
}
function Get-PriorityRouteProof([string]$RunPath) {
    # Text counts alone are insufficient: native routing must actually report
    # processing all eleven nets, and the log must name THIS PNR project.
    $log=Get-PriorityPath (Join-Path $RunPath 'pnr.log')
    Assert-PriorityNativeDiagnostics $log
    $text=[IO.File]::ReadAllText($log)
    $records=[regex]::Matches($text,'(?m)^Rcf routing step 1 processed ([0-9]+) nets(?:, it takes [0-9.]+ sec\.)?\r?$')
    $mentions=[regex]::Matches($text,'(?m)^.*Rcf routing step 1 processed.*$')
    if($records.Count -ne 1 -or $mentions.Count -ne 1 -or $records[0].Groups[1].Value -cne '11'){throw 'Native priority routing must process exactly 11 nets once'}
    $headers=[regex]::Matches($text,"(?m)^Analyzing project file '([^'\r\n]+)'\.\r?$")
    $project=Get-PriorityPath (Join-Path $RunPath 'geometry_priority_pnr.pds')
    if($headers.Count -ne 1 -or (Get-PriorityPath $headers[0].Groups[1].Value) -ine $project){throw 'Priority log native project substitution'}
    return [pscustomobject]@{path=$log;sha256=(Get-PriorityHash $log);match_count=1;processed_nets=11;native_project=$project}
}
function Assert-PriorityAudit([string]$Path) {
    $auditPath=Assert-PriorityInside $Path (Join-Path $script:PriorityFpga 'build')
    $state=Read-PriorityJson $auditPath
    if(!(Test-PriorityInteger $state.schema_version) -or $state.schema_version -ne 1){throw 'Unsupported audit schema'}
    Assert-PriorityBool $state.override_only $true 'override_only'
    Assert-PriorityBool $state.timing_budget_changed $false 'timing_budget_changed'
    Assert-PriorityBool $state.source_inputs_unchanged $true 'source_inputs_unchanged'
    Assert-PriorityBool $state.release_qualified $false 'release_qualified'
    $runPath=Assert-PriorityInside $state.run (Join-Path $script:PriorityFpga 'build')
    if($auditPath -ine (Join-Path $runPath 'priority_override.json')){throw 'Audit/run identity substitution'}
    if(!(Test-PriorityInteger $state.new_placement_seed) -or $state.new_placement_seed -lt 0 -or $state.new_placement_seed -gt 1000 -or
       !(Test-PriorityInteger $state.decongestion) -or $state.decongestion -lt 0 -or $state.decongestion -gt 9){throw 'Invalid native controls'}
    $candidate=Assert-PriorityInside $state.candidate_rcf (Join-Path $script:PriorityFpga 'build')
    $frozen=Get-PriorityPath (Join-Path $runPath 'routing/geometry_priority.rcf')
    if($candidate -ieq $frozen){throw 'Candidate cannot self-attest frozen copy'}
    Assert-PriorityRcf (Join-Path $script:PriorityFpga 'constraints/mini_raw8_dual/geometry_priority.rcf') 8
    Assert-PriorityRcf $candidate; Assert-PriorityRcf $frozen
    if((Get-PriorityHash $candidate) -ine (Get-PriorityHash $frozen)){throw 'Frozen RCF differs from candidate'}
    if((Get-PriorityHash (Join-Path $state.checkpoint 'source_manifest.json')) -ine (Get-PriorityHash (Join-Path $runPath 'source_manifest.json'))){throw 'Run source manifest changed'}
    $stages=@($state.stages); $order=@('configure','pnr','sta','sbit')
    if(!$stages.Count -or $stages.Count -gt 4){throw 'Missing native project evidence'}
    for($i=0;$i -lt $stages.Count;$i++){if($stages[$i] -cne $order[$i]){throw 'Invalid native stage sequence'}}
    $expected=@(Get-PriorityBindings $state)
    $nativeHashes=@(Read-PriorityJson (Join-Path $runPath 'checkpoint_hashes.json'))
    if(@($state.bindings).Count -ne $expected.Count -or $nativeHashes.Count -ne $expected.Count){throw 'Incomplete physical hash bindings'}
    foreach($entry in $expected){
        $record=@($state.bindings | Where-Object {$_.role -ceq $entry.role})
        if($record.Count -ne 1 -or (Get-PriorityPath $record[0].path) -ine $entry.path -or $record[0].sha256 -ine $entry.sha256){throw "Physical binding drift/substitution: $($entry.role)"}
        $hash=@($nativeHashes | Where-Object {(Get-PriorityPath $_.Path) -ieq $entry.path})
        if($hash.Count -ne 1 -or $hash[0].Algorithm -cne 'SHA256' -or $hash[0].Hash -ine $entry.sha256){throw 'Checkpoint hash binding drift'}
    }
    foreach($stage in $stages){Assert-PriorityProject (Join-Path $runPath ('geometry_priority_'+$stage+'.pds')) $state $stage}
    if($stages -contains 'pnr'){
        $proof=Get-PriorityRouteProof $runPath; $claimed=$state.native_priority_route
        if(!(Test-PriorityInteger $claimed.match_count) -or $claimed.match_count -ne 1 -or
          !(Test-PriorityInteger $claimed.processed_nets) -or $claimed.processed_nets -ne 11 -or
          (Get-PriorityPath $claimed.path) -ine $proof.path -or $claimed.sha256 -ine $proof.sha256 -or
          (Get-PriorityPath $claimed.native_project) -ine $proof.native_project){throw 'Native priority proof mismatch'}
    }
    return [pscustomobject]@{passed=$true;scope='physical_provenance_only';release_qualified=$false;
      native_priority_route_verified=($stages -contains 'pnr');run=$runPath;stages=$stages;bound_files=$expected.Count}
}
# CLI has exactly two alternative entry points. A caller cannot supply its
# own expected RCF, project path, allowlist, hash or relaxed validation mode.
if($MyInvocation.InvocationName -ne '.'){
    if([bool]$Audit -eq [bool]$Run){throw 'Specify exactly one of -Audit or -Run'}
    if($Run){$Audit=Join-Path (Get-PriorityPath $Run) 'priority_override.json'}
    $answer=Assert-PriorityAudit $Audit
    if(!$answer.native_priority_route_verified){throw 'Public gate requires completed PNR priority-log proof'}
    $answer
}
