# Purpose: retain identities and native-driver failure status for one MAP-only continuation.
# The Python preflight requires the actual GH2 RAM/FSM/CE proof and consumes its own claim.
# This wrapper never retries SYN, starts routing, changes a frozen source, or generates bitstreams.
$ErrorActionPreference = 'Stop'
$taskRoot = 'D:\XDU\concept\26-FPGA-Pango\fpga\build\gh2_integration_20261101'
Set-Location -LiteralPath 'D:\XDU\concept\26-FPGA-Pango'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$taskExit = 1
if ((Test-Path -LiteralPath "$taskRoot\map_launch_started.json") -or
    (Test-Path -LiteralPath "$taskRoot\map_launch_exit.json")) {
    throw 'MAP launch evidence already exists; inspect rather than restart.'
}
try {
    [ordered]@{started_at=(Get-Date -Format o);wrapper_pid=$PID;mode='MAP15_FROM_VERIFIED_GH2_SYN_ONLY'} |
        ConvertTo-Json | Set-Content -LiteralPath "$taskRoot\map_launch_started.json" -Encoding utf8
    & python -X utf8 -B fpga/scripts/evaluate_gh2_map_only.py --run
    $taskExit = $LASTEXITCODE
} catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
} finally {
    [ordered]@{ended_at=(Get-Date -Format o);wrapper_pid=$PID;returncode=$taskExit} |
        ConvertTo-Json | Set-Content -LiteralPath "$taskRoot\map_launch_exit.json" -Encoding utf8
}
exit $taskExit
