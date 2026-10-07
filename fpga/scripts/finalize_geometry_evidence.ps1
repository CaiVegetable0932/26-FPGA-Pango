# Purpose: independently bind fresh native min/max STA and SBIT to frozen inputs.
# No PNR, SFC conversion, hardware access, or modification of the original run.
# Contract: evidence.json v1; only the final path object is returned on success.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Run,
    [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4'
)
$ErrorActionPreference='Stop'

function Assert-GeometryTrue($Value, [string]$Name) {
    # Reject strings such as "false", which PowerShell otherwise treats as true.
    if($Value -isnot [bool] -or !$Value){throw "Required boolean is not true: $Name"}
}

function Get-GeometryRecord([string]$Role, [string]$Path) {
    # Record absolute file identities with SHA256. Empty tracked source placeholders
    # are legitimate; fresh native outputs have a separate nonempty-file gate.
    $item=Get-Item -LiteralPath $Path
    if($item.PSIsContainer){throw "Expected file input: $Path"}
    return [pscustomobject]@{role=$Role;path=$item.FullName;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}
}

function Assert-GeometryHashes($Entries) {
    # Both provenance schemas are normalized before this strict, nonempty check.
    if($null -eq $Entries -or @($Entries).Count -eq 0){throw 'Empty hash manifest'}
    foreach($entry in $Entries){
        if($null -eq $entry -or !$entry.path -or $entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$'){
            throw 'Malformed hash record'
        }
        $actual=Get-GeometryRecord 'verification' $entry.path
        if($actual.sha256 -ne $entry.sha256){throw "Changed input: $($entry.path)"}
    }
}

function Read-GeometryHashes([string]$Path, [switch]$NativeHash) {
    # Accept only the existing path/sha256 and Get-FileHash Path/Hash contracts.
    $raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if($null -eq $raw -or @($raw).Count -eq 0){throw "Empty manifest: $Path"}
    $records=@(foreach($entry in $raw){
        if($NativeHash){
            if($entry.Algorithm -ne 'SHA256'){throw "Wrong hash algorithm: $Path"}
            [pscustomobject]@{path=$entry.Path;sha256=$entry.Hash}
        }else{[pscustomobject]@{path=$entry.path;sha256=$entry.sha256}}
    })
    Assert-GeometryHashes $records
    return $records
}

function Resolve-GeometryRun([string]$Path, [string]$BuildRoot) {
    # Restrict writes to a real descendant; reject junction/symlink escape routes.
    $root=(Get-Item -LiteralPath $BuildRoot).FullName.TrimEnd('\','/')
    $item=Get-Item -LiteralPath $Path
    if(!$item.PSIsContainer -or !$item.FullName.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Run must be a directory inside this worktree fpga/build'
    }
    $cursor=$item
    while($null -ne $cursor){
        if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse-point run/build path is not allowed'}
        if($cursor.FullName -eq $root){return $item.FullName}
        $cursor=$cursor.Parent
    }
    throw 'Run is outside build root'
}

function Assert-GeometryFresh([string]$Path, [datetime]$StartedUtc) {
    # Fresh unique work directories plus UTC timestamps prevent reuse of old outputs.
    $item=Get-Item -LiteralPath $Path
    if($item.PSIsContainer -or $item.Length -eq 0 -or $item.LastWriteTimeUtc -lt $StartedUtc){
        throw "Missing, empty or stale output: $Path"
    }
}

function Get-GeometryTimingCoverage {
    # Purpose: minimum path topology for THIS board/constraint baseline, checked
    # against completed 20261006 release and 20261007 run13 reports. No old slack,
    # endpoint total, report hash or exact row count is an acceptance criterion.
    # Hold-only CDC exceptions remove cross-domain hold rows, not setup rows.
    # Recovery/removal concern reset release: serial reset launches at pixel_clk;
    # neither DDR data pairs nor the external RGMII endpoint belong in those tables.
    $local=@('rst_clk','ddrphy_sysclk','sys_clk','camera_pclk_budget','serial_clk','pixel_clk','ETH125')
    $data=@($local | ForEach-Object {$_+'>'+$_})+@(
        'phy_dq_sysclk_0>ddrphy_sysclk','phy_dq_sysclk_1>ddrphy_sysclk',
        'ddrphy_sysclk>phy_dq_sysclk_0','ddrphy_sysclk>phy_dq_sysclk_1','ETH125>PHY_SAMPLE')
    $reset=@($local | Where-Object {$_ -ne 'serial_clk'} | ForEach-Object {$_+'>'+$_})+@('pixel_clk>serial_clk')
    return @{
        Setup=$data+@('camera_pclk_budget>ddrphy_sysclk','sys_clk>ddrphy_sysclk',
            'pixel_clk>ddrphy_sysclk','ETH125>ddrphy_sysclk','ddrphy_sysclk>sys_clk',
            'ddrphy_sysclk>camera_pclk_budget','sys_clk>camera_pclk_budget',
            'ddrphy_sysclk>pixel_clk','ddrphy_sysclk>ETH125')
        Hold=$data;Recovery=$reset;Removal=$reset
        'Minimum Pulse Width'=$local+@('phy_dq_clk_0','phy_dq_clk_1','phy_dq_sysclk_0','phy_dq_sysclk_1')
    }
}

function Assert-GeometryTiming([string]$Text, [string]$Database) {
    # PDS 2022.2-SP6.4 may omit default min_max in command echoes. Require actual
    # ten populated, terminated corner summaries instead of trusting that echo.
    foreach($field in @(@('Device','PG2L100H'),@('Speed Grade','-6'),@('Package','FBG676'))){
        $pattern='(?m)^\|\s*'+[regex]::Escape($field[0])+'\s*:\s*'+[regex]::Escape($field[1])+'\s*\r?$'
        if([regex]::Matches($Text,$pattern).Count -ne 1){throw "Wrong/ambiguous report architecture: $($field[0])"}
    }
    if([regex]::Matches($Text,'(?m)^Timing analysis mode[^\r\n]*\r?$').Count -ne 1 -or
       $Text -notmatch '(?m)^Timing analysis mode\s*:\s*multi corner\s*\r?$' -or
       [regex]::Matches($Text,'(?m)^Design Summary[^\r\n]*\r?$').Count -ne 1 -or
       [regex]::Matches($Text,'(?m)^Design Summary\s*:\s*All Constraints Met\.\s*\r?$').Count -ne 1 -or
       $Text -match '(?m)^\s*E:') {throw 'Timing report does not pass multi-corner analysis'}
    # Check the explicit input table, not an incidental path in a warning/comment.
    $inputRows=[regex]::Matches($Text,'(?m)^\|\s*Input\s*\|\s*(?<path>[^\r\n|]+?)\s*\|?\s*\r?$')
    if($inputRows.Count -ne 1){throw 'Missing/ambiguous report input DB'}
    $reported=$inputRows[0].Groups['path'].Value.Trim().Replace('/','\')
    if(![string]::Equals($reported,$Database.Replace('/','\'),[StringComparison]::OrdinalIgnoreCase)){
        throw 'Timing report belongs to another input DB'
    }
    # Require exactly ten named corner tables. Unknown/duplicate corners or
    # dangling extra headings cannot hide behind the ten expected matches.
    $headings=[regex]::Matches($Text,'(?m)^(Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\([^\r\n]*\):[^\r\n]*\r?$')
    if($headings.Count -ne 10){throw 'Expected exactly ten corner summary tables'}
    $coverage=Get-GeometryTimingCoverage
    $lastSummaryEnd=0
    foreach($corner in @('Slow','Fast')){
        foreach($kind in @('Setup','Hold','Recovery','Removal','Minimum Pulse Width')){
            $heading=[regex]::Escape("$kind Summary($corner Corner):")
            $sections=[regex]::Matches($Text,'(?ms)^'+$heading+'[^\S\r\n]*\r?\n(?<body>.*?)^={5,}[^\S\r\n]*\r?$')
            if($sections.Count -ne 1){throw "Missing/duplicate/incomplete summary: $kind $corner"}
            $body=$sections[0].Groups['body'].Value
            if($body -match 'Summary\('){throw "Unterminated summary: $kind $corner"}
            $lastSummaryEnd=[Math]::Max($lastSummaryEnd,$sections[0].Index+$sections[0].Length)
            # Parse the complete four-line native header, then EVERY data line.
            # Regex Matches over a whole body silently discarded malformed rows.
            $lines=@($body -split '\r?\n' | ForEach-Object {$_.Trim()} | Where-Object {$_ -ne ''})
            $pulse=$kind -eq 'Minimum Pulse Width'
            $totalLabel=if($pulse){'WPWS'}elseif($kind -in @('Hold','Removal')){'THS'}else{'TNS'}
            $worstLabel=if($pulse){'WPWS'}elseif($kind -in @('Hold','Removal')){'WHS'}else{'WNS'}
            $sumLabel=if($pulse){'TPWS'}else{$totalLabel}
            $columns=if($pulse){'Clock'}else{'Launch Clock Capture Clock'}
            $expectedColumns="$columns $worstLabel(ns) $sumLabel(ns) Endpoints Endpoints"
            if($lines.Count -lt 5 -or $lines[0] -notmatch '^\*{5,}$' -or
               ($lines[1] -replace '\s+',' ') -cne "$totalLabel Failing $totalLabel Total" -or
               ($lines[2] -replace '\s+',' ') -cne $expectedColumns -or $lines[3] -notmatch '^-{5,}$'){
                throw "Malformed/empty summary header: $kind $corner"
            }
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $prefix=if($pulse){'(?<launch>\S+)'}else{'(?<launch>\S+)\s+(?<capture>\S+)'}
            $rowPattern='^'+$prefix+'\s+(?<worst>-?\d+\.\d+)\s+(?<total>-?\d+\.\d+)\s+(?<failing>\d+)\s+(?<endpoints>\d+)$'
            foreach($line in $lines[4..($lines.Count-1)]){
                $row=[regex]::Match($line,$rowPattern)
                if(!$row.Success){throw "Malformed summary row: $kind $corner : $line"}
                $key=$row.Groups['launch'].Value
                if(!$pulse){$key+='>'+$row.Groups['capture'].Value}
                if(!$seen.Add($key)){throw "Duplicate summary row: $kind $corner : $key"}
                $culture=[Globalization.CultureInfo]::InvariantCulture
                $worst=[double]::Parse($row.Groups['worst'].Value,$culture)
                $total=[double]::Parse($row.Groups['total'].Value,$culture)
                if([double]::IsInfinity($worst) -or [double]::IsNaN($worst) -or
                   $worst -lt 0 -or $total -ne 0 -or [long]$row.Groups['failing'].Value -ne 0 -or
                   [long]$row.Groups['endpoints'].Value -le 0){throw "Failing/empty summary row: $kind $corner : $key"}
            }
            foreach($required in $coverage[$kind]){
                if(!$seen.Contains($required)){throw "Missing required timing coverage: $kind $corner : $required"}
            }
        }
    }
    # This completion footer must be at EOF, after the input/output table.
    if($inputRows[0].Index -le $lastSummaryEnd -or
       [regex]::Matches($Text,'(?m)^Total real time to report_timing completion[^\r\n]*\r?$').Count -ne 1 -or
       $Text -notmatch '(?m)^Total real time to report_timing completion\s*:\s*\d+h:\d+m:\d+(?:\.\d+)?s\s*\z'){
        throw 'Missing final report completion line'
    }
}

function Assert-GeometryNativeLog([string]$Text, [int]$ExitCode, [string]$Marker) {
    # An emitted Tcl marker cannot override a native error or unresolved constraints.
    if($ExitCode -ne 0 -or $Text -notmatch ('(?m)^\s*'+[regex]::Escape($Marker)+'\s*\r?$') -or
       $Text -match '(?im)^\s*E:|Check license failed|STA-301[35]|cannot find|matches no|No .* found'){
        throw "Native invocation failed: $Marker (exit $ExitCode)"
    }
}

function Invoke-GeometryNative([string]$Exe, [string]$Script, [string]$Directory,
                              [hashtable]$Environment, [string]$Log, [string]$Marker) {
    # Use a child-only environment: no Process/User/Machine environment is mutated.
    # Capture both streams without deadlock. License diagnostics are redacted before
    # logging/display; validation always sees the original text, including errors.
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Exe
    $start.Arguments='-file "'+$Script+'" -work_dir "'+$Directory+'"'
    $start.WorkingDirectory=$Directory
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($name in $Environment.Keys){$start.EnvironmentVariables[$name]=[string]$Environment[$name]}
    $license=$start.EnvironmentVariables['PANGO_LICENSE_FILE']
    if([string]::IsNullOrWhiteSpace($license)){$license=[Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','User')}
    if(![string]::IsNullOrWhiteSpace($license)){$start.EnvironmentVariables['PANGO_LICENSE_FILE']=$license}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        if(!$process.Start()){throw 'Unable to start native finalization stage'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text=$stdout.GetAwaiter().GetResult()+[Environment]::NewLine+$stderr.GetAwaiter().GetResult()
        $safe=$text
        if(![string]::IsNullOrEmpty($license)){$safe=$safe.Replace($license,'[REDACTED]')}
        $safe=[regex]::Replace($safe,'(?im)^.*(?:license|PANGO_LICENSE_FILE).*$', '[license diagnostic redacted]')
        [IO.File]::WriteAllText($Log,$safe,[Text.UTF8Encoding]::new($false))
        $safe | Out-Host
        Assert-GeometryNativeLog $text $process.ExitCode $Marker
    } finally {$process.Dispose()}
}

# Allocate only after checking containment; even preflight failures get their own
# failed evidence record. Keep paths short for the installed Windows native PDS
# runtime; milliseconds plus a random suffix avoid overwriting earlier evidence.
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Resolve-GeometryRun $Run (Join-Path $taskFpga 'build')
$taskDir=Join-Path $taskRun ('final_'+(Get-Date -Format 'HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $taskDir | Out-Null
$taskEvidencePath=Join-Path $taskDir 'evidence.json'
$taskInputs=[Collections.Generic.List[object]]::new()
$taskOutputs=[Collections.Generic.List[object]]::new()
$taskEvidence=[ordered]@{schema_version=1;passed=$false;run=$taskRun;inputs=@();outputs=@();
    timing_constraints_met=$false;multi_corner_min_max_verified=$false;programmed=$false;
    error=$null;finalization_dir=$taskDir;native_logs_license_redacted=$true;created_utc=[DateTime]::UtcNow.ToString('o')}
try {
    # Freeze the provenance documents before checking their contents; later checks
    # detect a concurrent edit rather than silently accepting a new source baseline.
    foreach($name in @('result.json','source_manifest.json','checkpoint_hashes.json','routed_db_hash.json')){
        $taskInputs.Add((Get-GeometryRecord ('original_'+$name) (Join-Path $taskRun $name)))
    }
    $result=Get-Content -LiteralPath (Join-Path $taskRun 'result.json') -Raw | ConvertFrom-Json
    foreach($flag in @('native_stage_completed','timing_constraints_met','source_inputs_unchanged','bitstream_generated')){
        Assert-GeometryTrue $result.$flag $flag
    }
    $sources=@(Read-GeometryHashes (Join-Path $taskRun 'source_manifest.json'))
    $checkpoint=@(Read-GeometryHashes (Join-Path $taskRun 'checkpoint_hashes.json') -NativeHash)
    $routed=@(Read-GeometryHashes (Join-Path $taskRun 'routed_db_hash.json') -NativeHash)
    $originalDb=(Get-Item -LiteralPath (Join-Path $taskRun 'routed_snapshot/mini_raw8_geometry_pnr.adf')).FullName
    if($routed.Count -ne 1 -or ![string]::Equals($routed[0].path,$originalDb,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Routed hash must identify exactly this run routed_snapshot DB'
    }
    $index=0
    foreach($entry in @($sources)+@($checkpoint)){
        $taskInputs.Add([pscustomobject]@{role=('provenance_'+$index);path=$entry.path;sha256=$entry.sha256});$index++
    }
    $taskInputs.Add([pscustomobject]@{role='original_routed_db';path=$originalDb;sha256=$routed[0].sha256})
    $exe=(Get-Item -LiteralPath (Join-Path $PdsHome 'bin/pds_shell.exe')).FullName
    $taskInputs.Add((Get-GeometryRecord 'pds_exe' $exe))
    $taskInputs.Add((Get-GeometryRecord 'original_runner' $PSCommandPath))

    # Identical script copies retain the scripts/../constraints topology so Tcl's
    # [info script] resolves only the frozen constraints, never mutable originals.
    $snapshot=Join-Path $taskDir 'inputs/fpga'
    $copySpecs=@(
        @('routed_db',$originalDb,'routed_snapshot/mini_raw8_geometry_pnr.adf'),
        @('timing_script',(Join-Path $PSScriptRoot 'inspect_geometry_timing.tcl'),'scripts/inspect_geometry_timing.tcl'),
        @('bitstream_script',(Join-Path $PSScriptRoot 'export_geometry_sbit.tcl'),'scripts/export_geometry_sbit.tcl'),
        @('runner',$PSCommandPath,'scripts/finalize_geometry_evidence.ps1')
    )
    foreach($name in @('result.json','source_manifest.json','checkpoint_hashes.json','routed_db_hash.json')){
        $copySpecs+=,@(('frozen_'+$name),(Join-Path $taskRun $name),('provenance/'+$name))
    }
    # Capture the actual constraint set from the existing Tcl foreach, and fail
    # closed if its loading shape changes. No substitute or relaxed constraints.
    $taskInputs.Add((Get-GeometryRecord 'constraint_discovery_script' (Join-Path $PSScriptRoot 'inspect_geometry_timing.tcl')))
    $timingText=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'inspect_geometry_timing.tcl') -Raw
    $constraintBlock=[regex]::Matches($timingText,'(?s)foreach\s+path\s+\{(?<paths>[^}]+)\}\s*\{add_constraint\s+\[file join \$fpga_root \$path\]\}')
    if($constraintBlock.Count -ne 1 -or $timingText -notmatch '-delay_type\s+min_max\b'){throw 'Unexpected native timing script contract'}
    $constraintPaths=@($constraintBlock[0].Groups['paths'].Value.Trim() -split '\s+')
    if($constraintPaths.Count -eq 0){throw 'No timing constraints'}
    foreach($relative in $constraintPaths){
        if($relative -notmatch '^constraints/[A-Za-z0-9_./-]+\.(fdc|rcf)$' -or $relative.Contains('..')){throw 'Unsafe constraint path'}
        $copySpecs+=,@(('constraint_'+$relative),(Join-Path $taskFpga $relative),$relative)
    }
    foreach($spec in $copySpecs){
        $source=Get-GeometryRecord ('source_'+$spec[0]) $spec[1]
        $taskInputs.Add($source)
        $dest=Join-Path $snapshot $spec[2]
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        if(Test-Path -LiteralPath $dest){throw "Snapshot destination already exists: $dest"}
        Copy-Item -LiteralPath $source.path -Destination $dest
        $copy=Get-GeometryRecord $spec[0] $dest
        if($copy.sha256 -ne $source.sha256){throw 'Input changed while copying'}
        $taskInputs.Add($copy)
    }
    Assert-GeometryHashes $taskInputs.ToArray()
    $db=($taskInputs | Where-Object {$_.role -eq 'routed_db'}).path
    $timingScript=($taskInputs | Where-Object {$_.role -eq 'timing_script'}).path
    $bitstreamScript=($taskInputs | Where-Object {$_.role -eq 'bitstream_script'}).path
    $report=Join-Path $taskDir 'report_timing/mini_raw8_geometry.rtr'
    $sbit=Join-Path $taskDir 'generate_bitstream/mini_raw8_geometry.sbit'
    $timingLog=Join-Path $taskDir 'timing.log';$bitstreamLog=Join-Path $taskDir 'bitstream.log'
    # The child overrides only its own variables; ambient diagnostic path count
    # cannot alter this final analysis. Neither stage invokes native PNR.
    $environment=@{GEOMETRY_DIAG_DB=$db;GEOMETRY_DIAG_IMPL=$taskDir;GEOMETRY_DIAG_PATHS='10';
        GEOMETRY_IMPL=$taskDir;GEOMETRY_PNR_DB=$db}
    if(Test-Path -LiteralPath $report){throw 'Unexpected pre-existing timing report'}
    $started=[DateTime]::UtcNow
    Invoke-GeometryNative $exe $timingScript $taskDir $environment $timingLog 'GEOMETRY_DIAGNOSTIC_STA_COMPLETED'
    Assert-GeometryFresh $report $started
    Assert-GeometryTiming (Get-Content -LiteralPath $report -Raw) $db
    $taskOutputs.Add((Get-GeometryRecord 'timing_report' $report))
    $taskOutputs.Add((Get-GeometryRecord 'timing_log' $timingLog))
    Assert-GeometryHashes $taskInputs.ToArray()
    $taskEvidence.timing_constraints_met=$true;$taskEvidence.multi_corner_min_max_verified=$true
    if(Test-Path -LiteralPath $sbit){throw 'Unexpected pre-existing SBIT'}
    $started=[DateTime]::UtcNow
    Invoke-GeometryNative $exe $bitstreamScript $taskDir $environment $bitstreamLog 'GEOMETRY_EXACT_PNR_IMAGE_GENERATED'
    Assert-GeometryFresh $sbit $started
    $taskOutputs.Add((Get-GeometryRecord 'sbit' $sbit))
    $taskOutputs.Add((Get-GeometryRecord 'bitstream_log' $bitstreamLog))
    # The report is checked again after image generation as well as all original
    # and frozen inputs. Record no success if anything changed between stages.
    Assert-GeometryHashes $taskInputs.ToArray()
    Assert-GeometryHashes $taskOutputs.ToArray()
    $taskEvidence.passed=$true
} catch {
    $taskEvidence.error=$_.Exception.Message
    throw
} finally {
    # Failure evidence is deliberately non-native-ready; consumers must require
    # passed=true and all four unique output roles before using any artifact.
    $taskEvidence.inputs=@($taskInputs.ToArray());$taskEvidence.outputs=@($taskOutputs.ToArray())
    $taskEvidence.completed_utc=[DateTime]::UtcNow.ToString('o')
    $taskEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskEvidencePath -Encoding UTF8
    Write-Host "GEOMETRY_FINALIZATION_EVIDENCE $taskEvidencePath passed=$($taskEvidence.passed)"
}
[pscustomobject]@{evidence_path=$taskEvidencePath;finalization_dir=$taskDir}
