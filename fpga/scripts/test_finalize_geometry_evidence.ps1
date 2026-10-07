# Purpose: pure validation/negative tests. Never starts PDS or creates passing
# native evidence; all synthetic data is labeled test-only under fpga/build.
[CmdletBinding()]
param([string]$ReferenceReport='')
$ErrorActionPreference='Stop'
$taskRunner=Join-Path $PSScriptRoot 'finalize_geometry_evidence.ps1'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskTest=Join-Path $taskFpga ('build/finalization_tests_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskTest | Out-Null
$taskResults=[Collections.Generic.List[object]]::new()

# Load only function definitions from the production AST. The runner entry point
# and its native invocation are never evaluated by the helper tests.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($taskRunner,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
foreach($node in $ast.EndBlock.Statements){
    if($node -is [Management.Automation.Language.FunctionDefinitionAst]){
        . ([scriptblock]::Create($node.Extent.Text))
    }
}

function Test-GeometryCase([string]$Name, [scriptblock]$Action, [switch]$Reject) {
    # Record every assertion independently; an expected rejection must actually throw.
    $caught=$null
    try {& $Action | Out-Null} catch {$caught=$_.Exception.Message}
    $passed=if($Reject){$null -ne $caught}else{$null -eq $caught}
    $script:taskResults.Add([pscustomobject]@{name=$Name;passed=$passed;expected_rejection=[bool]$Reject;error=$caught})
}

# Construct a minimal native-shaped report in memory. It is parser test data,
# never evidence of real STA, routed placement, or a bitstream build.
$taskDb=Join-Path $taskTest 'synthetic_pnr.adf'
$taskHeader="| Device : PG2L100H`n| Speed Grade : -6`n| Package : FBG676`nTiming analysis mode : multi corner`nDesign Summary : All Constraints Met.`n"
# Purpose: independent fixture topology matching the documented board baseline;
# do not call the production coverage helper to generate its own expected data.
$taskLocal=@('rst_clk','ddrphy_sysclk','sys_clk','camera_pclk_budget','serial_clk','pixel_clk','ETH125')
$taskData=@($taskLocal | ForEach-Object {$_+' '+$_})+@(
    'phy_dq_sysclk_0 ddrphy_sysclk','phy_dq_sysclk_1 ddrphy_sysclk',
    'ddrphy_sysclk phy_dq_sysclk_0','ddrphy_sysclk phy_dq_sysclk_1','ETH125 PHY_SAMPLE')
$taskReset=@('rst_clk rst_clk','ddrphy_sysclk ddrphy_sysclk','sys_clk sys_clk',
    'camera_pclk_budget camera_pclk_budget','pixel_clk serial_clk','pixel_clk pixel_clk','ETH125 ETH125')
$taskPairs=@{
    Setup=$taskData+@('camera_pclk_budget ddrphy_sysclk','sys_clk ddrphy_sysclk',
        'pixel_clk ddrphy_sysclk','ETH125 ddrphy_sysclk','ddrphy_sysclk sys_clk',
        'ddrphy_sysclk camera_pclk_budget','sys_clk camera_pclk_budget',
        'ddrphy_sysclk pixel_clk','ddrphy_sysclk ETH125')
    Hold=$taskData;Recovery=$taskReset;Removal=$taskReset
    'Minimum Pulse Width'=$taskLocal+@('phy_dq_clk_0','phy_dq_clk_1','phy_dq_sysclk_0','phy_dq_sysclk_1')
}
$taskSummaries=''
foreach($corner in @('Slow','Fast')){foreach($kind in @('Setup','Hold','Recovery','Removal','Minimum Pulse Width')){
    $header= switch($kind){
        'Minimum Pulse Width' {"WPWS Failing WPWS Total`nClock WPWS(ns) TPWS(ns) Endpoints Endpoints"}
        {$_ -in @('Hold','Removal')} {"THS Failing THS Total`nLaunch Clock Capture Clock WHS(ns) THS(ns) Endpoints Endpoints"}
        default {"TNS Failing TNS Total`nLaunch Clock Capture Clock WNS(ns) TNS(ns) Endpoints Endpoints"}
    }
    $taskSummaries+="$kind Summary($corner Corner):`n**********`n$header`n----------`n"
    foreach($pair in $taskPairs[$kind]){$taskSummaries+="$pair 0.100 0.000 0 5`n"}
    $taskSummaries+="==========`n"
}}
$taskFooter="Inputs and Outputs :`n| Input | $($taskDb.Replace('\','/'))`nTotal real time to report_timing completion : 0h:0m:3s`n"
$taskReport=$taskHeader+$taskSummaries+$taskFooter
Test-GeometryCase 'complete synthetic min/max structure' {Assert-GeometryTiming $taskReport $taskDb}
Test-GeometryCase 'missing report completion' {Assert-GeometryTiming ($taskHeader+$taskSummaries) $taskDb} -Reject
Test-GeometryCase 'trailing content after completion' {Assert-GeometryTiming ($taskReport+'unfinished') $taskDb} -Reject
Test-GeometryCase 'wrong routed database' {Assert-GeometryTiming $taskReport ($taskDb+'.other')} -Reject
Test-GeometryCase 'wrong architecture' {Assert-GeometryTiming ($taskReport.Replace('PG2L100H','PG2L200H')) $taskDb} -Reject
Test-GeometryCase 'wrong speed' {Assert-GeometryTiming ($taskReport.Replace('Grade : -6','Grade : -5')) $taskDb} -Reject
Test-GeometryCase 'wrong package' {Assert-GeometryTiming ($taskReport.Replace('FBG676','FBG484')) $taskDb} -Reject
Test-GeometryCase 'single corner' {Assert-GeometryTiming ($taskReport.Replace('multi corner','single corner')) $taskDb} -Reject
Test-GeometryCase 'failing design summary' {Assert-GeometryTiming ($taskReport.Replace('All Constraints Met.','Constraints NOT Met.')) $taskDb} -Reject
Test-GeometryCase 'negative slack despite passing summary' {Assert-GeometryTiming ($taskReport.Replace('0.100','-0.100')) $taskDb} -Reject
Test-GeometryCase 'nonzero failing endpoints' {Assert-GeometryTiming ($taskReport.Replace('0.000 0 5','0.000 1 5')) $taskDb} -Reject
Test-GeometryCase 'duplicate input DB' {Assert-GeometryTiming ($taskReport.Replace('Inputs and Outputs :',"| Input | $taskDb`nInputs and Outputs :")) $taskDb} -Reject
Test-GeometryCase 'native error inside report' {Assert-GeometryTiming ("E: failure`n"+$taskReport) $taskDb} -Reject
foreach($corner in @('Slow','Fast')){foreach($kind in @('Setup','Hold','Recovery','Removal','Minimum Pulse Width')){
    $taskHeading="$kind Summary($corner Corner):"
    Test-GeometryCase "missing $taskHeading" {Assert-GeometryTiming ($taskReport.Replace($taskHeading,'REMOVED')) $taskDb} -Reject
}}
Test-GeometryCase 'empty summary tables' {Assert-GeometryTiming ([regex]::Replace($taskReport,'(?m)^\S[^\r\n]+ 0.100 0.000 0 5\r?\n','')) $taskDb} -Reject
Test-GeometryCase 'unterminated summary tables' {Assert-GeometryTiming ($taskReport.Replace('==========','')) $taskDb} -Reject

# Native-log checks are pure string validation, including success with an error,
# bad exit status, unresolved constraints, and success marker echoed as Tcl text.
Test-GeometryCase 'valid native marker' {Assert-GeometryNativeLog "GEOMETRY_DIAGNOSTIC_STA_COMPLETED`n" 0 'GEOMETRY_DIAGNOSTIC_STA_COMPLETED'}
Test-GeometryCase 'marker with failing exit' {Assert-GeometryNativeLog 'PASS' 1 'PASS'} -Reject
Test-GeometryCase 'marker with native error' {Assert-GeometryNativeLog "PASS`nE: bad" 0 'PASS'} -Reject
Test-GeometryCase 'marker with unresolved constraints' {Assert-GeometryNativeLog "PASS`nSTA-3015 unresolved" 0 'PASS'} -Reject
Test-GeometryCase 'echoed marker is not execution' {Assert-GeometryNativeLog 'puts PASS' 0 'PASS'} -Reject
Test-GeometryCase 'boolean true' {Assert-GeometryTrue $true 'test'}
Test-GeometryCase 'string true rejected' {Assert-GeometryTrue 'true' 'test'} -Reject
Test-GeometryCase 'boolean false rejected' {Assert-GeometryTrue $false 'test'} -Reject
Test-GeometryCase 'null boolean rejected' {Assert-GeometryTrue $null 'test'} -Reject

# All filesystem fixtures are new test files. Hash drift, stale outputs, schema
# mismatches, and path escape are exercised without changing any original input.
$taskFile=Join-Path $taskTest 'fixture.txt'
'SYNTHETIC TEST ONLY' | Set-Content -LiteralPath $taskFile
$taskRecord=Get-GeometryRecord 'test' $taskFile
Test-GeometryCase 'current SHA256' {Assert-GeometryHashes @($taskRecord)}
Test-GeometryCase 'empty hashes' {Assert-GeometryHashes @()} -Reject
Test-GeometryCase 'null hashes' {Assert-GeometryHashes $null} -Reject
Test-GeometryCase 'malformed hash' {Assert-GeometryHashes @([pscustomobject]@{path=$taskFile;sha256='bad'})} -Reject
'CHANGED SYNTHETIC TEST ONLY' | Set-Content -LiteralPath $taskFile
Test-GeometryCase 'changed input' {Assert-GeometryHashes @($taskRecord)} -Reject
Test-GeometryCase 'fresh artifact' {Assert-GeometryFresh $taskFile ([DateTime]::UtcNow.AddMinutes(-1))}
Test-GeometryCase 'stale artifact' {Assert-GeometryFresh $taskFile ([DateTime]::UtcNow.AddMinutes(1))} -Reject
Test-GeometryCase 'build root forbidden' {Resolve-GeometryRun (Join-Path $taskFpga 'build') (Join-Path $taskFpga 'build')} -Reject
Test-GeometryCase 'outside build forbidden' {Resolve-GeometryRun $PSScriptRoot (Join-Path $taskFpga 'build')} -Reject
Test-GeometryCase 'test descendant accepted' {Resolve-GeometryRun $taskTest (Join-Path $taskFpga 'build')}
$taskEmpty=Join-Path $taskTest 'empty.json';'[]' | Set-Content -LiteralPath $taskEmpty
Test-GeometryCase 'empty JSON manifest' {Read-GeometryHashes $taskEmpty} -Reject
$taskWrong=Join-Path $taskTest 'wrong_algorithm.json'
@{Algorithm='MD5';Path=$taskFile;Hash=('0'*64)} | ConvertTo-Json | Set-Content -LiteralPath $taskWrong
Test-GeometryCase 'wrong hash algorithm' {Read-GeometryHashes $taskWrong -NativeHash} -Reject

# Invoke the real entry point only with missing provenance, so it must terminate
# before native startup. Its failed evidence must remain distinguishable from a
# native pass and repeated attempts must create separate finalization directories.
$taskBadRun=Join-Path $taskTest 'missing_provenance'
New-Item -ItemType Directory -Path $taskBadRun | Out-Null
$taskEnvBefore=[Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','Process')
foreach($attempt in 1..2){
    Test-GeometryCase "real preflight rejects incomplete run $attempt" {& $taskRunner -Run $taskBadRun -PdsHome (Join-Path $taskTest 'NO_NATIVE_EXECUTABLE')} -Reject
}
Test-GeometryCase 'failed attempts preserved separately' {
    # The runner uses a short final_ prefix to keep native Windows paths bounded.
    $dirs=@(Get-ChildItem -LiteralPath $taskBadRun -Directory -Filter 'final_*')
    if($dirs.Count -ne 2){throw 'Failure outputs were overwritten'}
    foreach($dir in $dirs){
        $e=Get-Content -LiteralPath (Join-Path $dir.FullName 'evidence.json') -Raw | ConvertFrom-Json
        if($e.schema_version -ne 1 -or $e.passed -ne $false -or !$e.error -or $e.programmed -ne $false){throw 'Invalid failure evidence'}
    }
}
Test-GeometryCase 'parent license environment unchanged' {
    if([Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','Process') -cne $taskEnvBefore){throw 'Parent environment changed'}
}

# Optional known-complete historical report is used only as a parser fixture.
# Callers must explicitly choose a finished report; no active reports are scanned.
if($ReferenceReport){
    $reference=Get-Content -LiteralPath $ReferenceReport -Raw
    $match=[regex]::Match($reference,'(?m)^\|\s*Input\s*\|\s*(?<path>[^\r\n|]+?)\s*\|?\s*\r?$')
    Test-GeometryCase 'completed historical report format (not fresh evidence)' {
        if(!$match.Success){throw 'No DB path in historical fixture'}
        Assert-GeometryTiming $reference $match.Groups['path'].Value.Trim()
    }
}
# Purpose: preserve the original 51 checks (including the optional real report)
# and add the independent audit reproductions. Mutations stay in memory; no
# native invocation or change to real timing results/DBs occurs in these tests.
function Edit-TestSummary([string]$Report,[string]$Kind,[string]$Corner,[scriptblock]$Edit) {
    $pattern='(?ms)^'+[regex]::Escape("$Kind Summary($Corner Corner):")+'.*?^={5,}[^\S\r\n]*\r?$'
    $m=[regex]::Match($Report,$pattern)
    if(!$m.Success){throw 'Test section not found'}
    return $Report.Substring(0,$m.Index)+(& $Edit $m.Value)+$Report.Substring($m.Index+$m.Length)
}
foreach($corner in @('Slow','Fast')){foreach($kind in @('Setup','Hold','Recovery','Removal','Minimum Pulse Width')){
    foreach($pair in $taskPairs[$kind]){
        Test-GeometryCase "missing coverage $kind $corner $pair" {
            $changed=Edit-TestSummary $taskReport $kind $corner {param($s) $s.Replace("$pair 0.100 0.000 0 5`n",'')}
            Assert-GeometryTiming $changed $taskDb
        } -Reject
    }
    $first=$taskPairs[$kind][0]
    foreach($invalid in @('-0.250 TRUNCATED 1 132273','NaN 0.000 0 5','Infinity 0.000 0 5',
        '0.100 0.000 0 0','0.100 0.000 0 5 EXTRA','0.100 0.000 0','0.100 0.000 1 5')){
        Test-GeometryCase "malformed or failing row $kind $corner $invalid" {
            $changed=Edit-TestSummary $taskReport $kind $corner {param($s) $s.Replace("$first 0.100 0.000 0 5","$first $invalid")}
            Assert-GeometryTiming $changed $taskDb
        } -Reject
    }
    Test-GeometryCase "duplicate row $kind $corner" {
        $changed=Edit-TestSummary $taskReport $kind $corner {param($s) $s.Replace("$first 0.100 0.000 0 5","$first 0.100 0.000 0 5`n$first 0.100 0.000 0 5")}
        Assert-GeometryTiming $changed $taskDb
    } -Reject
}}
Test-GeometryCase 'missing all core DDR RGMII rows' {
    $changed=[regex]::Replace($taskReport,'(?m)^(?!rst_clk)\S[^\r\n]+ 0.100 0.000 0 5\r?\n','')
    Assert-GeometryTiming $changed $taskDb
} -Reject
Test-GeometryCase 'eleventh corner table rejected' {
    Assert-GeometryTiming ($taskReport.Replace('Inputs and Outputs :',"Setup Summary(Typical Corner):`n==========`nInputs and Outputs :")) $taskDb
} -Reject
Test-GeometryCase 'duplicate completion footer rejected' {
    Assert-GeometryTiming ($taskReport.Replace('Inputs and Outputs :',"Total real time to report_timing completion : 0h:0m:1s`nInputs and Outputs :")) $taskDb
} -Reject
Test-GeometryCase 'duplicate analysis mode rejected' {
    Assert-GeometryTiming ("Timing analysis mode : single corner`n"+$taskReport) $taskDb
} -Reject
Test-GeometryCase 'no old WNS or endpoint total fixed' {
    Assert-GeometryTiming ($taskReport.Replace('0.100 0.000 0 5','1.234 0.000 0 123456')) $taskDb
}
Test-GeometryCase 'additional valid path rows permitted' {
    $changed=Edit-TestSummary $taskReport 'Setup' 'Slow' {param($s) $s.Replace('==========',"extra_clock other_clock 0.001 0.000 0 1`n==========")}
    Assert-GeometryTiming $changed $taskDb
}
Test-GeometryCase 'recovery removal do not require DDR or RGMII data pairs' {
    # Each reset table has seven rows, unlike 21 setup / 12 hold. Deliberately
    # no DDR read/write pair, ETH125>PHY_SAMPLE or serial_clk self-reset row.
    foreach($kind in @('Recovery','Removal')){
        if($taskPairs[$kind].Count -ne 7){throw 'Unexpected fixture topology'}
    }
    Assert-GeometryTiming $taskReport $taskDb
}
if($ReferenceReport){
    Test-GeometryCase 'native report malformed negative row is rejected' {
        $changed=Edit-TestSummary $reference 'Setup' 'Slow' {param($s)
            [regex]::Replace($s,'(?m)^\s*ddrphy_sysclk\s+ddrphy_sysclk[^\r\n]*',' ddrphy_sysclk ddrphy_sysclk -0.250 TRUNCATED 1 132273')
        }
        Assert-GeometryTiming $changed $match.Groups['path'].Value.Trim()
    } -Reject
    Test-GeometryCase 'native report partial tables are rejected' {
        $pattern='(?ms)^(Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary\((Slow|Fast) Corner\):.*?^={5,}[^\S\r\n]*\r?$'
        $changed=[regex]::Replace($reference,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($m)
            [regex]::Replace($m.Value,'(?m)^\s*(ddrphy_sysclk|phy_dq_sysclk_[01]|ETH125|camera_pclk_budget|pixel_clk|serial_clk|sys_clk|phy_dq_clk_[01])[^\r\n]*\r?\n','')
        })
        Assert-GeometryTiming $changed $match.Groups['path'].Value.Trim()
    } -Reject
}

# Purpose: prove the old explicit-evidence bypass is gone without executing the
# exporter. Its parameter-only stub must reject the old option, and its AST must
# invoke the real finalizer unconditionally at the top level before reading JSON.
$exportPath=Join-Path $PSScriptRoot 'export_geometry_candidate.ps1'
$exportAst=[Management.Automation.Language.Parser]::ParseFile($exportPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
Test-GeometryCase 'exporter rejects legacy FinalizationEvidence argument' {
    $stub=[scriptblock]::Create($exportAst.ParamBlock.Extent.Text+"`nthrow 'STUB_BODY_MUST_NOT_RUN'")
    $argsMap=@{}
    foreach($p in $exportAst.ParamBlock.Parameters){$argsMap[$p.Name.VariablePath.UserPath]='unused'}
    $argsMap['FinalizationEvidence']='old-evidence.json'
    try {& $stub @argsMap;throw 'Legacy argument accepted'}catch{
        if($_.FullyQualifiedErrorId -notlike '*NamedParameterNotFound*'){throw}
    }
}
Test-GeometryCase 'fresh finalizer is unconditional and owns evidence path' {
    $calls=@($exportAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$taskFinalized'
    })
    if($calls.Count -ne 1 -or $calls[0].Right.Extent.Text -notmatch "finalize_geometry_evidence\.ps1.*-Run \`$taskRun"){
        throw 'Missing unconditional current-run finalizer'
    }
    $text=$exportAst.Extent.Text
    if($text -match '\$FinalizationEvidence\b' -or
       $text -notmatch '\$taskFinalEvidence=Resolve-Build \$taskFinalized\.evidence_path'){
        throw 'Caller/inherited evidence can bypass fresh generation'
    }
}
$taskFailed=@($taskResults | Where-Object {!$_.passed})
# Bind the pure-test result to these reviewed scripts and the explicitly chosen
# completed report; this is parser evidence, never new native timing evidence.
$taskTestInputs=@($taskRunner,$exportPath,$PSCommandPath)
if($ReferenceReport){$taskTestInputs+=$ReferenceReport}
[ordered]@{test_only=$true;native_pds_executed=$false;native_release_qualified=$false;
    powershell=$PSVersionTable.PSVersion.ToString();
    inputs=@($taskTestInputs | ForEach-Object {Get-FileHash -LiteralPath $_});
    passed=($taskFailed.Count -eq 0);count=$taskResults.Count;tests=@($taskResults.ToArray())} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskTest 'test_result.json') -Encoding UTF8
if($taskFailed.Count){$taskFailed | Format-Table -Wrap | Out-Host;throw "$($taskFailed.Count) finalization tests failed: $taskTest"}
[pscustomobject]@{passed=$true;tests=$taskResults.Count;test_result=(Join-Path $taskTest 'test_result.json');native_pds_executed=$false}
