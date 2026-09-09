param(
    [string]$PdsRoot = '',
    [string]$IpRoot = ''
)

$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content (Join-Path $fpgaRoot 'config\toolchain.json') -Raw | ConvertFrom-Json
if (-not $PdsRoot) { $PdsRoot = $toolchain.pds_root }
if (-not $IpRoot) { $IpRoot = Join-Path $fpgaRoot 'ip' }
$generator = Join-Path $PdsRoot 'bin\ip_generate.exe'
if (-not (Test-Path -LiteralPath $generator)) { throw "IP generator not found: $generator" }

$instances = @(
    (Join-Path $IpRoot 'pll_100h\pll.idf'),
    (Join-Path $IpRoot 'line_fifo_100h\fifo_test.idf'),
    (Join-Path $IpRoot 'line_ram_100h\ram_test.idf'),
    (Join-Path $IpRoot 'ddr3_100h\ddr3_test.idf')
)

$failed = @()
foreach ($idf in $instances) {
    if (-not (Test-Path -LiteralPath $idf)) { throw "IP instance file not found: $idf" }
    $instanceDir = Split-Path -Parent $idf
    Write-Host "GENERATE $idf"
    & $generator -i $idf -m (Join-Path $PdsRoot 'ip') -ads -log generate.log
    if ($LASTEXITCODE -ne 0) { $failed += $idf }
}
if ($failed.Count -gt 0) {
    throw "One or more IP generations failed; inspect each instance generate.log: $($failed -join ', ')"
}
Write-Host 'PANGO_VIDEO_IP_GENERATION_PASS'
