param(
    [ValidateSet('doctor','test','build','simlib','report')][string]$Action = 'doctor',
    [string]$OutDir,
    [ValidateSet('rtl','synthesis','route_function','timing_min','timing_max','all')][string]$Stage = 'rtl',
    [string]$BuildDir,
    [string]$RepeatDir,
    [string]$TestsDir,
    [string]$SimlibDir,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path -Parent $PSScriptRoot
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'
if ($Action -eq 'report') {
    if (!$BuildDir -or !$RepeatDir -or !$TestsDir -or !$SimlibDir) { throw 'report requires BuildDir, RepeatDir, TestsDir and SimlibDir' }
    & $Python (Join-Path $PSScriptRoot 'report.py') --build-dir $BuildDir --repeat-dir $RepeatDir --tests-dir $TestsDir --simlib-dir $SimlibDir
} else {
    if (!$OutDir) { $OutDir = Join-Path $fpgaRoot ('build/' + $Action + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')) }
    $flowArgs = @((Join-Path $PSScriptRoot 'flow.py'), $Action, '--out', $OutDir)
    if ($Action -eq 'test') {
        $flowArgs += @('--stage', $Stage)
        if ($BuildDir) { $flowArgs += @('--build-dir', $BuildDir) }
        if ($SimlibDir) { $flowArgs += @('--simlib-dir', $SimlibDir) }
    }
    & $Python @flowArgs
}
if ($LASTEXITCODE -ne 0) { throw "Offline flow returned $LASTEXITCODE; inspect retained reports." }
