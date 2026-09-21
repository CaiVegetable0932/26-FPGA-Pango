# Purpose: run native PDS GTP_ODDR_E1 / GTP_GRS models, never local stubs.
# Official model files are read-only inputs; libraries, logs and waveforms
# stay in a fresh fpga/build/rgmii_tx_* directory derived from this script.
param(
    [string]$ModelSimHome = 'E:/ModelsimSE/win64',
    [string]$PdsHome = 'E:/PDS_Pangu/PDS_2022.2-SP6.4'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskFpga = Split-Path $PSScriptRoot -Parent
$taskModelRoot = Join-Path $PdsHome 'arch/vendor/pango/verilog/simulation'
$taskModels = @(
    (Join-Path $taskModelRoot 'GTP_GRS.v'),
    (Join-Path $taskModelRoot 'GTP_ODDR_E1.v')
)
$taskRtl = Join-Path $taskFpga 'rtl/network/pango_rgmii_tx.v'
$taskBench = Join-Path $taskFpga 'sim/tb_pango_rgmii_tx.sv'

# Validate inputs before creating output; only the two required official GTP
# sources are compiled. There is no model copy, generated substitute or stub.
foreach ($taskPath in ($taskModels + @($taskRtl, $taskBench))) {
    if (!(Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Missing input: $taskPath" }
}
foreach ($taskTool in @('vmap.exe', 'vlib.exe', 'vlog.exe', 'vsim.exe')) {
    if (!(Test-Path -LiteralPath (Join-Path $ModelSimHome $taskTool) -PathType Leaf)) {
        throw "Missing ModelSim tool: $taskTool in $ModelSimHome"
    }
}
$taskModelManifest = @($taskModels | ForEach-Object {
    [pscustomobject]@{ path = $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash }
})
$taskSourceManifest = @(@($taskRtl, $taskBench, $PSCommandPath) | ForEach-Object {
    [pscustomobject]@{ path = $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash }
})
$taskRun = Join-Path $taskFpga ('build/rgmii_tx_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null

# All tool calls run in the isolated output directory; exit codes are checked
# in addition to transcript markers so compilation failures cannot pass.
function Invoke-RgmiiTool {
    param([string]$Tool, [string[]]$ToolArgs, [string]$LogName)
    & (Join-Path $ModelSimHome $Tool) @ToolArgs 2>&1 |
        Tee-Object -FilePath (Join-Path $taskRun $LogName)
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed with exit code $LASTEXITCODE ($LogName)" }
}

# Use a local modelsim.ini and restore the caller's process environment even
# on failure; no installation-wide library mapping or configuration is edited.
$taskPreviousModelsim = $env:MODELSIM
$taskPassed = $false
$taskFailure = $null
$taskSummary = $null
$taskSimulatorVersion = $null
$taskModelsUnchanged = $false
Push-Location $taskRun
try {
    Remove-Item Env:MODELSIM -ErrorAction SilentlyContinue
    Invoke-RgmiiTool -Tool 'vmap.exe' -ToolArgs @('-c') -LogName 'vmap_init.log'
    $env:MODELSIM = Join-Path $taskRun 'modelsim.ini'
    foreach ($taskLibrary in @('work', 'usim')) {
        Invoke-RgmiiTool -Tool 'vlib.exe' -ToolArgs @($taskLibrary) -LogName ("vlib_$taskLibrary.log")
        Invoke-RgmiiTool -Tool 'vmap.exe' -ToolArgs @($taskLibrary, $taskLibrary) -LogName ("vmap_$taskLibrary.log")
    }
    $taskSimulatorVersion = (& (Join-Path $ModelSimHome 'vsim.exe') -version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read ModelSim version' }

    # usim is deliberately a minimal native GTP library for this unit, not a
    # claim to have compiled the entire PDS device library or any VOP/SDF model.
    Invoke-RgmiiTool -Tool 'vlog.exe' -ToolArgs (@('-work', 'usim') + $taskModels) -LogName 'compile_native.log'
    Invoke-RgmiiTool -Tool 'vlog.exe' -ToolArgs @('-work', 'work', $taskRtl) -LogName 'compile_rtl.log'
    Invoke-RgmiiTool -Tool 'vlog.exe' -ToolArgs @('-sv', '-work', 'work', $taskBench) -LogName 'compile_tb.log'

    # Keep primitive instances visible for provenance instead of allowing
    # vopt to inline them. Error handlers belong in a real ModelSim macro.
    @'
onerror {quit -f -code 2}
onbreak {quit -f -code 3}
log -r /*
run -all
quit -f -code 0
'@ | Set-Content -LiteralPath (Join-Path $taskRun 'run.do') -Encoding ascii
    Invoke-RgmiiTool -Tool 'vsim.exe' -ToolArgs @(
        '-c', '-novopt', '-t', '1ps', '-L', 'usim', '-onfinish', 'exit',
        '-wlf', 'rgmii_tx.wlf', 'work.tb_pango_rgmii_tx',
        '-do', 'do run.do'
    ) -LogName 'simulation.log'

    # Demand a full-count result, explicit PASS, zero errors, and transcript
    # evidence that both loaded primitives came from usim rather than work.
    $taskTranscript = Get-Content -LiteralPath (Join-Path $taskRun 'simulation.log') -Raw
    $taskAllLogs = (@('compile_native.log', 'compile_rtl.log', 'compile_tb.log', 'simulation.log') |
        ForEach-Object { Get-Content -LiteralPath (Join-Path $taskRun $_) -Raw }) -join "`n"
    $taskResult = [regex]::Match($taskTranscript,
        'RGMII_TX_RESULT checks=(\d+) errors=(\d+) vectors=(\d+) local_resets=(\d+) global_resets=(\d+) txc_rises=(\d+) txc_falls=(\d+)')
    if (!$taskResult.Success) { throw 'Missing complete RGMII_TX_RESULT counters' }
    $taskSummary = [ordered]@{
        checks = [int]$taskResult.Groups[1].Value
        errors = [int]$taskResult.Groups[2].Value
        vectors = [int]$taskResult.Groups[3].Value
        local_resets = [int]$taskResult.Groups[4].Value
        global_resets = [int]$taskResult.Groups[5].Value
        txc_rises = [int]$taskResult.Groups[6].Value
        txc_falls = [int]$taskResult.Groups[7].Value
    }
    $taskPassed = ($taskTranscript -match '(?m)^#\s*RGMII_TX_PASS\s*$') -and
        ($taskAllLogs -notmatch '\*\*\s+(Error|Fatal)|RGMII_TX_(CHECK_FAILED|FAILED|TIMEOUT)|Error: Illegal') -and
        ($taskTranscript -match 'Loading usim\.GTP_ODDR_E1') -and
        ($taskTranscript -match 'Loading usim\.GTP_GRS') -and
        ($taskSummary.errors -eq 0) -and ($taskSummary.vectors -eq 3072) -and
        ($taskSummary.local_resets -eq 4) -and ($taskSummary.global_resets -eq 1)
    if (!$taskPassed) { throw 'Native-model identity, counters, or transcript checks failed' }
} catch {
    $taskFailure = $_.Exception.Message
    $taskPassed = $false
} finally {
    # Hash official inputs again and retain provenance plus measured counters;
    # neither proprietary source text nor license contents enter the results.
    try {
        $taskModelsUnchanged = $true
        foreach ($taskModel in $taskModelManifest) {
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $taskModel.path).Hash -ne $taskModel.sha256) {
                $taskModelsUnchanged = $false
            }
        }
        if (!$taskModelsUnchanged) { $taskPassed = $false; $taskFailure = 'Official model hash changed' }
        [ordered]@{
            passed = $taskPassed
            failure = $taskFailure
            completed_at = (Get-Date -Format o)
            run_directory = $taskRun
            simulator = $taskSimulatorVersion
            pds_root = $PdsHome
            official_models = $taskModelManifest
            official_models_unchanged = $taskModelsUnchanged
            sources = $taskSourceManifest
            summary = $taskSummary
            scope = 'Native GTP functional simulation; 3 x 256 x 4 continuous byte/control cases'
            same_edge_latency_cycles = 1
            clock_period_ns = 8
            forwarded_clock_lag_ns = 2
            board_verified = $false
            synthesis_run = $false
            phy_txid_verified = $false
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskRun 'result.json') -Encoding utf8
    } finally {
        if ($null -eq $taskPreviousModelsim) { Remove-Item Env:MODELSIM -ErrorAction SilentlyContinue }
        else { $env:MODELSIM = $taskPreviousModelsim }
        Pop-Location
    }
}
if (!$taskPassed) { throw "RGMII native simulation failed: $taskFailure; evidence: $taskRun" }
Write-Output "RGMII_TX_NATIVE_PASS $taskRun"
