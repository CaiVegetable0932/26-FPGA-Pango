# Purpose: offline MCU UART pin-level regression and optional standalone ADS
# synthesis. All generated work/logs/netlists stay in a fresh mcu_protocol run.
param(
    [string]$ModelSimHome = 'E:/ModelsimSE/win64',
    [string]$PdsHome = 'E:/PDS_Pangu/PDS_2022.2-SP6.4',
    [switch]$Synthesize
)
$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path $PSScriptRoot -Parent
$runRoot = Join-Path $fpgaRoot ('build/mcu_protocol_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
$sources = @('mcu_uart_rx.v','mcu_uart_tx.v','mcu_frame_rx.v','mcu_frame_tx.v','mcu_protocol.v') |
    ForEach-Object { Join-Path $fpgaRoot "rtl/control/$_" }
$testbench = Join-Path $fpgaRoot 'sim/tb_mcu_protocol.sv'
$summary = [ordered]@{
    started = (Get-Date).ToString('o'); passed = $false; simulation_passed = $false
    synthesis_requested = [bool]$Synthesize; synthesis_passed = $false
    hardware_tested = $false; mcu_firmware_tested = $false; programmed = $false
    runs = @(); source_sha256 = @(); output_directory = $runRoot
}
# Hash exactly the inputs consumed by this run, including the entry script.
$summary.source_sha256 = @(@($sources) + @($testbench,$PSCommandPath) | ForEach-Object {
    $hash = Get-FileHash -LiteralPath $_ -Algorithm SHA256
    [ordered]@{path=$hash.Path; sha256=$hash.Hash}
})
$oldLicense = $env:PANGO_LICENSE_FILE
Push-Location $runRoot
try {
    # Pure RTL behavior simulation has no vendor primitive or IP library needs.
    & "$ModelSimHome/vsim.exe" -version 2>&1 | Set-Content -LiteralPath 'modelsim_version.log' -Encoding utf8
    & "$ModelSimHome/vlib.exe" work 2>&1 | Tee-Object -FilePath 'vlib.log'
    if ($LASTEXITCODE -ne 0) { throw 'ModelSim vlib failed' }
    & "$ModelSimHome/vlog.exe" -sv @sources $testbench 2>&1 | Tee-Object -FilePath 'compile.log'
    if ($LASTEXITCODE -ne 0) { throw 'ModelSim compile failed' }

    # A small exact-divider clock covers the full abuse suite;125MHz exercises
    # actual integration parameters, true115200 serial bits and default20ms.
    $configurations = @(
        @{name='full'; clock=1843200; timeout=2; full=1},
        @{name='clock125'; clock=125000000; timeout=20; full=0}
    )
    foreach ($configuration in $configurations) {
        $logPath = Join-Path $runRoot ($configuration.name + '.log')
        $arguments = @('-c','tb_mcu_protocol',"-gCLK_HZ=$($configuration.clock)",
            "-gRX_TIMEOUT_MS=$($configuration.timeout)","-gFULL=$($configuration.full)",
            '-wlf',(Join-Path $runRoot ($configuration.name + '.wlf')),
            '-do','onerror {quit -code 2}; onbreak {quit -code 2}; run -all; quit -f')
        & "$ModelSimHome/vsim.exe" @arguments 2>&1 | Tee-Object -FilePath $logPath
        $nativeExit = $LASTEXITCODE
        $passed = $nativeExit -eq 0 -and
            (Select-String -Path $logPath -Pattern 'MCU_PROTOCOL_PASS' -Quiet) -and
            !(Select-String -Path $logPath -Pattern 'MCU_PROTOCOL_FAIL|\*\* (Error|Fatal)' -Quiet)
        $summary.runs += [ordered]@{name=$configuration.name; clock_hz=$configuration.clock;
            baud=115200; timeout_ms=$configuration.timeout; full=[bool]$configuration.full;
            exit_code=$nativeExit; passed=$passed; log=$logPath}
        if (!$passed) { throw "MCU UART regression failed: $logPath" }
    }
    $summary.simulation_passed = $true

    # Optional synthesis follows installed ADS manual shell flow, using the
    # verified100H target and no physical IO insertion or pin assignments.
    if ($Synthesize) {
        $synthRoot = Join-Path $runRoot 'ads125'
        New-Item -ItemType Directory -Path $synthRoot | Out-Null
        $tcl = @('# Generated standalone MCU synthesis; no PNR or programming.',
            'set_arch -family Logos2 -device PG2L100H -package FBG676 -speedgrade -6')
        foreach ($source in $sources) { $tcl += ('add_design -verilog {' + $source.Replace('\','/') + '}') }
        $tcl += @('compile -top_module mcu_protocol -defined_parameters {CLK_HZ 125000000 BAUD 115200 RX_TIMEOUT_MS 20}',
            'synthesize -ads -disable_io_insertion -frequency 125', 'puts {MCU_ADS_SYNTH_PASS}')
        $tclPath = Join-Path $synthRoot 'mcu_synth.tcl'
        $tcl | Set-Content -LiteralPath $tclPath -Encoding ascii
        if (!$env:PANGO_LICENSE_FILE) { $env:PANGO_LICENSE_FILE = [Environment]::GetEnvironmentVariable('PANGO_LICENSE_FILE','User') }
        Push-Location $synthRoot
        try {
            $synthLog = Join-Path $synthRoot 'synthesis.log'
            & "$PdsHome/bin/pds_shell.exe" -file $tclPath -work_dir $synthRoot 2>&1 |
                Tee-Object -FilePath $synthLog
            $synthExit = $LASTEXITCODE
            $netlists = @(Get-ChildItem -LiteralPath $synthRoot -Recurse -Filter '*_syn.vm')
            $summary.synthesis_passed = $synthExit -eq 0 -and $netlists.Count -gt 0 -and
                (Select-String -Path $synthLog -Pattern 'MCU_ADS_SYNTH_PASS' -Quiet) -and
                !(Select-String -Path $synthLog -Pattern '(?m)^E:|Check license failed|\*\* (Error|Fatal)' -Quiet)
            $summary.synthesis_exit = $synthExit
            $summary.synthesis_netlists = @($netlists | ForEach-Object { $_.FullName })
            if (!$summary.synthesis_passed) { throw "MCU ADS synthesis failed: $synthLog" }
        } finally { Pop-Location }
    }
    $summary.passed = $true
    Write-Output "MCU_PROTOCOL_SIM_PASS $runRoot"
} finally {
    # Always retain a machine-readable result, even for compile/license failures.
    $summary.finished = (Get-Date).ToString('o')
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'result.json') -Encoding utf8
    $env:PANGO_LICENSE_FILE = $oldLicense
    Pop-Location
}
