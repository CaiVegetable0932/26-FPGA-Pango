# Purpose: isolated native GTP regression of the frozen same-source RGMII
# branch contract. Never changes RTL, official models, global tool settings,
# hardware or Git. Every attempt gets a unique fpga/build directory.
param(
    [string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
    [string]$ModelSimHome='E:/ModelsimSE/win64'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/rgmii_dedicated_clock_'+(Get-Date -Format yyyyMMdd_HHmmss_fff)+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskFrozen=Join-Path $taskRun 'sources'
New-Item -ItemType Directory -Path $taskFrozen | Out-Null
$taskBoard=Join-Path $taskFpga 'rtl/board/mini_raw8_geometry.v'
$taskRtl=Join-Path $taskFpga 'rtl/network/pango_rgmii_tx.v'
$taskBench=Join-Path $taskFpga 'sim/tb_rgmii_dedicated_clock.sv'
$taskExpectedBoard='39EAC934A1718849B0A37CE2D5D3D42E040736A4EE1A830045A5743C99D19A53'
$taskModels=@('GTP_GRS.v','GTP_ODDR_E1.v','GTP_CLKBUFG.v' | ForEach-Object {Join-Path $PdsHome ('arch/vendor/pango/verilog/simulation/'+$_)})
$taskInputSpecs=@(
    [pscustomobject]@{path=$PSCommandPath;role='runner';compiled=$false},
    [pscustomobject]@{path=$taskBench;role='bench';compiled=$true},
    [pscustomobject]@{path=$taskRtl;role='dut_rtl';compiled=$true},
    [pscustomobject]@{path=$taskBoard;role='board_binding_contract_only';compiled=$false}
)
foreach($taskModel in $taskModels) {
    $taskInputSpecs+=[pscustomobject]@{path=$taskModel;role='installed_native_model';compiled=$true}
}
$taskBefore=@();$taskAfter=@();$taskSummary=$null;$taskFailure=$null
$taskPassed=$false;$taskUnchanged=$false;$taskVersion=$null;$taskContract=$false
$taskPreviousModelsim=$env:MODELSIM

# Hash each actual input before and after execution. BoardTop is provenance
# only; the compile list deliberately contains no board or PLL implementation.
function Get-DedicatedManifest {
    @($taskInputSpecs | ForEach-Object {
        [ordered]@{path=$_.path;role=$_.role;compiled=$_.compiled;
            sha256=(Get-FileHash -LiteralPath $_.path -Algorithm SHA256).Hash}
    })
}

# Each tool runs inside this attempt's directory, with captured logs and exit
# checks. usim is a minimal library compiled from the three installed files.
function Invoke-DedicatedTool {
    param([string]$Tool,[string[]]$ToolArgs,[string]$Log)
    & (Join-Path $ModelSimHome $Tool) @ToolArgs 2>&1 | Tee-Object -FilePath (Join-Path $taskRun $Log)
    if($LASTEXITCODE -ne 0) {throw "$Tool exit=$LASTEXITCODE; log=$Log"}
}

Push-Location $taskRun
try {
    foreach($taskInput in $taskInputSpecs) {
        if(!(Test-Path -LiteralPath $taskInput.path -PathType Leaf)) {throw "Missing input: $($taskInput.path)"}
    }
    $taskBefore=Get-DedicatedManifest
    $taskBefore | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskRun 'sources_before.json') -Encoding utf8
    foreach($taskInput in $taskInputSpecs | Where-Object role -ne 'installed_native_model') {
        Copy-Item -LiteralPath $taskInput.path -Destination (Join-Path $taskFrozen (Split-Path $taskInput.path -Leaf))
    }

    # Exact frozen SHA plus comment-stripped binding checks tie this unit to
    # native23 without pretending that the full BoardTop was elaborated.
    if((Get-FileHash -LiteralPath $taskBoard -Algorithm SHA256).Hash -ne $taskExpectedBoard) {throw 'Frozen native23 BoardTop SHA mismatch'}
    $taskTop=Get-Content -LiteralPath (Join-Path $taskFrozen 'mini_raw8_geometry.v') -Raw
    $taskTop=[regex]::Replace($taskTop,'(?s)/\*.*?\*/|(?m)//[^\r\n]*','')
    foreach($taskPattern in @(
        'GTP_CLKBUFG\s+u_eth_clock\s*\(\s*\.CLKIN\(eth_raw\),\s*\.CLKOUT\(eth_clk\)\s*\)',
        'GTP_CLKBUFG\s+u_eth_tx_clock\s*\(\s*\.CLKIN\(eth_raw\),\s*\.CLKOUT\(eth_tx_clk\)\s*\)',
        'comms_pll\s+u_eth_pll\([^;]*\.clkout0\(eth_raw\)',
        'u_gmii_bridge\([^;]*\.rd_clk\(eth_clk\)',
        'pango_rgmii_tx\s*#\(\s*\.PHY_TXID\(1\),\s*\.SEPARATE_TXC_RESET\(1\)\)\s+u_rgmii\(\.clk125\(eth_tx_clk\),\.clk125_90\(eth_tx_clk\),\s*\.reset_n\(eth_tx_reset_n\),\.txc_reset_n\(1''b1\)'
    )) {if($taskTop -notmatch $taskPattern) {throw "Board binding mismatch: $taskPattern"}}
    $taskContract=$true
    foreach($taskTool in @('vmap.exe','vlib.exe','vlog.exe','vsim.exe')) {
        if(!(Test-Path -LiteralPath (Join-Path $ModelSimHome $taskTool) -PathType Leaf)) {throw "Missing tool: $taskTool"}
    }
    Remove-Item Env:MODELSIM -ErrorAction SilentlyContinue
    Invoke-DedicatedTool 'vmap.exe' @('-c') 'vmap_init.log'
    $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
    foreach($taskLib in @('work','usim')) {
        Invoke-DedicatedTool 'vlib.exe' @($taskLib) ("vlib_$taskLib.log")
        Invoke-DedicatedTool 'vmap.exe' @($taskLib,$taskLib) ("vmap_$taskLib.log")
    }
    $taskVersion=(& (Join-Path $ModelSimHome 'vsim.exe') -version 2>&1 | Out-String).Trim()
    if($LASTEXITCODE) {throw 'Simulator version query failed'}
    Invoke-DedicatedTool 'vlog.exe' (@('-work','usim')+$taskModels) 'compile_native.log'
    Invoke-DedicatedTool 'vlog.exe' @('-work','work',(Join-Path $taskFrozen 'pango_rgmii_tx.v')) 'compile_rtl.log'
    Invoke-DedicatedTool 'vlog.exe' @('-sv','-work','work',(Join-Path $taskFrozen 'tb_rgmii_dedicated_clock.sv')) 'compile_tb.log'

    # Generated control macro is an output artifact, not a global simulator
    # setting. Break/error handlers ensure a fatal never becomes a success.
    @'
onerror {quit -f -code 2}
onbreak {quit -f -code 3}
log -r /*
run -all
quit -f -code 0
'@ | Set-Content -LiteralPath (Join-Path $taskRun 'run.do') -Encoding ascii
    Invoke-DedicatedTool 'vsim.exe' @('-c','-novopt','-t','1ps','-L','usim','-onfinish','exit',
        '-wlf','dedicated_clock.wlf','work.tb_rgmii_dedicated_clock','-do','do run.do') 'simulation.log'
    $taskTranscript=Get-Content -LiteralPath (Join-Path $taskRun 'simulation.log') -Raw
    $taskLogs=(@('compile_native.log','compile_rtl.log','compile_tb.log','simulation.log') |
        ForEach-Object {Get-Content -LiteralPath (Join-Path $taskRun $_) -Raw}) -join "`n"
    $taskMatch=[regex]::Match($taskTranscript,'DEDICATED_CLOCK_RESULT checks=(\d+) errors=(\d+) vectors=(\d+) random_vectors=(\d+) resets=(\d+) phase_edges=(\d+) txc_rises=(\d+) txc_falls=(\d+) reset_txc_edges=(\d+) phase_delta_ps=(\d+)')
    if(!$taskMatch.Success) {throw 'Missing complete counters'}
    $taskSummary=[ordered]@{}
    $taskKeys=@('checks','errors','vectors','random_vectors','resets','phase_edges','txc_rises','txc_falls','reset_txc_edges','phase_delta_ps')
    for($taskIndex=0;$taskIndex -lt $taskKeys.Count;$taskIndex++) {$taskSummary[$taskKeys[$taskIndex]]=[int]$taskMatch.Groups[$taskIndex+1].Value}
    foreach($taskName in @('GTP_GRS','GTP_ODDR_E1','GTP_CLKBUFG')) {
        if($taskTranscript -notmatch ('Loading usim\.'+$taskName+'\b')) {throw "Native model identity missing: $taskName"}
    }
    $taskPassed=($taskTranscript -match '(?m)^#\s*DEDICATED_CLOCK_PASS\s*$') -and
        ($taskLogs -notmatch '\*\*\s+(Error|Fatal)|DEDICATED_CLOCK_(CHECK_FAILED|FAILED|TIMEOUT)|Error: Illegal') -and
        ($taskSummary.errors -eq 0) -and ($taskSummary.vectors -eq 3072) -and
        ($taskSummary.random_vectors -eq 1024) -and ($taskSummary.resets -eq 4) -and
        ($taskSummary.phase_delta_ps -eq 0) -and ($taskSummary.reset_txc_edges -ge 32)
    if(!$taskPassed) {throw 'Counters or transcript acceptance failed'}
} catch {
    $taskFailure=$_.Exception.Message;$taskPassed=$false
} finally {
    # Retain before/after hashes, frozen local sources and failures in their
    # original attempt directories. Never overwrite a previous attempt.
    try {
        $taskAfter=Get-DedicatedManifest
        $taskAfter | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskRun 'sources_after.json') -Encoding utf8
        $taskUnchanged=($taskBefore.Count -eq $taskAfter.Count) -and ($taskBefore.Count -gt 0)
        for($taskIndex=0;$taskIndex -lt $taskBefore.Count;$taskIndex++) {
            if($taskBefore[$taskIndex].sha256 -ne $taskAfter[$taskIndex].sha256) {$taskUnchanged=$false}
            if($taskBefore[$taskIndex].role -ne 'installed_native_model') {
                $taskCopy=Join-Path $taskFrozen (Split-Path $taskBefore[$taskIndex].path -Leaf)
                if((Get-FileHash -LiteralPath $taskCopy -Algorithm SHA256).Hash -ne $taskBefore[$taskIndex].sha256) {$taskUnchanged=$false}
            }
        }
        if(!$taskUnchanged) {$taskPassed=$false;$taskFailure='Input SHA changed or frozen snapshot mismatch; '+$taskFailure}
    } catch {$taskPassed=$false;$taskFailure='Manifest finalization failed: '+$_.Exception.Message}
    [ordered]@{
        passed=$taskPassed;failure=$taskFailure;run_directory=$taskRun;completed_at=(Get-Date -Format o);
        pds_version='2022.2-SP6.4';pds_root=$PdsHome;simulator=$taskVersion;
        sources_before=$taskBefore;sources_after=$taskAfter;sources_unchanged=$taskUnchanged;
        board_sha256=$taskExpectedBoard;board_binding_contract_checked=$taskContract;
        compiled_inputs=@($taskModels)+@((Join-Path $taskFrozen 'pango_rgmii_tx.v'),(Join-Path $taskFrozen 'tb_rgmii_dedicated_clock.sv'));
        summary=$taskSummary;random_seed='C10C1251';period_ns=8;sample_settle_ps=50;
        scope='Native GTP functional unit simulation: old single BUFG versus new two same-source BUFGs';
        boardtop_compiled=$false;pll_compiled=$false;routed_clock_verified=$false;hardware_tested=$false;video_1080p30_verified=$false;
        reference_directory_present=(Test-Path -LiteralPath (Join-Path (Split-Path $taskFpga -Parent) 'reference'))
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $taskRun 'result.json') -Encoding utf8
    if($null -eq $taskPreviousModelsim) {Remove-Item Env:MODELSIM -ErrorAction SilentlyContinue}
    else {$env:MODELSIM=$taskPreviousModelsim}
    Pop-Location
}
if(!$taskPassed) {throw "Dedicated clock simulation failed: $taskFailure; evidence=$taskRun"}
Write-Output "RGMII_DEDICATED_CLOCK_NATIVE_PASS $taskRun"
