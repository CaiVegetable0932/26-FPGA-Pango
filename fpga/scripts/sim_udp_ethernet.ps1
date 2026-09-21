# Purpose: compile Verilog RTL plus SV stimulus, then independently decode actual
# GMII bytes in Python. Generated artifacts stay in a new fpga/build run directory.
param(
    [string]$ModelSimHome = 'E:/ModelsimSE/win64',
    [string]$Python = 'C:/Users/ROG/AppData/Local/Programs/Python/Python312/python.exe',
    [int]$Seed = 1729,
    [ValidateRange(8, 1024)][int]$RxTimeoutCycles = 32
)
$ErrorActionPreference = 'Stop'
$udpFpga = Split-Path $PSScriptRoot -Parent
$udpRun = Join-Path $udpFpga ('build/udp_ethernet/sim_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$udpRtl = Join-Path $udpFpga 'rtl/network/udp_ipv4_eth_tx.v'
$udpBench = Join-Path $udpFpga 'sim/tb_udp_ipv4_eth_tx.sv'
$udpChecker = Join-Path $udpFpga 'sim/check_ethernet_tx.py'
New-Item -ItemType Directory -Path $udpRun | Out-Null
Push-Location $udpRun
try {
    # Work library/transcript/WLF remain isolated; no installed library, official
    # example or PDS project is modified. This RTL uses no vendor primitives.
    & "$ModelSimHome/vsim.exe" -version 2>&1 | Tee-Object -FilePath version.log
    if ($LASTEXITCODE -ne 0) { throw 'ModelSim version query failed' }
    & "$ModelSimHome/vlib.exe" work
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    & "$ModelSimHome/vlog.exe" -work work $udpRtl 2>&1 | Tee-Object -FilePath compile_rtl.log
    if ($LASTEXITCODE -ne 0) { throw 'Verilog RTL compilation failed' }
    & "$ModelSimHome/vlog.exe" -sv -work work $udpBench 2>&1 | Tee-Object -FilePath compile_tb.log
    if ($LASTEXITCODE -ne 0) { throw 'SystemVerilog bench compilation failed' }
    $udpSimArgs = @('-c', '-lib', './work', 'tb_udp_ipv4_eth_tx',
        "-gRX_TIMEOUT_CYCLES=$RxTimeoutCycles", "+SEED=$Seed",
        '-wlf', 'simulation.wlf', '-l', 'transcript.log',
        '-do', 'onerror {quit -code 2}; onbreak {quit -code 3}; run -all; quit -f')
    & "$ModelSimHome/vsim.exe" @udpSimArgs 2>&1 | Tee-Object -FilePath simulation.log
    $udpSimExit = $LASTEXITCODE
    $udpPassed = $udpSimExit -eq 0 -and
        (Select-String -Path simulation.log -Pattern 'UDP_ETH_PASS' -Quiet) -and
        !(Select-String -Path simulation.log -Pattern 'UDP_ETH_FAIL|UDP_ETH_TIMEOUT|\*\* (Error|Fatal)' -Quiet)
    if (!$udpPassed) { throw "RTL regression failed: $udpRun" }

    # Independently check metadata, payload, CRC, IP checksum, timeout and cycles.
    $udpCheckArgs = @('-B', $udpChecker, '--trace', 'gmii_trace.csv',
        '--timeout-cycles', "$RxTimeoutCycles", '--output', 'check_result.json')
    & $Python @udpCheckArgs 2>&1 | Tee-Object -FilePath python_check.log
    if ($LASTEXITCODE -ne 0) { throw "Independent Python verification failed: $udpRun" }
    $udpHashes = @($udpRtl, $udpBench, $udpChecker, $PSCommandPath) |
        ForEach-Object { [ordered]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } }
    [ordered]@{
        passed = $true; native_exit = $udpSimExit; seed = $Seed
        timeout_cycles = $RxTimeoutCycles; scope = 'UDP/IPv4/Ethernet GMII RTL simulation'
        hardware_tested = $false; synthesis_tested = $false; timing_closed = $false
        source_files = $udpHashes
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath run_result.json -Encoding utf8
    Write-Output "UDP_ETHERNET_SIM_PASS $udpRun"
} finally {
    Pop-Location
}
