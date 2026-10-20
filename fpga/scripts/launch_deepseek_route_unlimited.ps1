# Unlimited-continuation routing launch, user-instructed after the seed-13 90-minute
# comparison (2026-10-20 evening). Same project/frozen inputs as launch_deepseek_route_round.ps1.
# Purpose: if seed 13 beat seed 11's 41,449 unrouted at the 90-minute cap, restart the
#          same seed-13 PnR with the time limit removed so routing can run to
#          completion: 0 unrouted -> min/max STA -> bitgen (burnable bitstream goal).
# Time-limit semantics inside the tool's safety structure:
#   - --pnr-timeout-minutes 0: official meaning is NO native action timeout;
#   - --phase-timeout-minutes 1440: host bound must stay finite (1..1440 minutes),
#     so 24 hours is the largest legal value; the convergence stall rule and the
#     user stop file still terminate the round earlier when needed;
#   - routing is deterministic for a fixed seed, so this round replays the completed
#     iterations and then continues past the previous cap.
# Hard constraints: exactly one PDS executor; frozen sources/MAP/PCF/timing untouched;
# bitgen only after routed min/max STA reports "All Constraints Met"; no JTAG download
# or board burn; stop file recorded as a path only, never pre-created.
# Note: intentionally pure ASCII; Windows PowerShell 5.1 misparses non-ASCII in
# BOM-less .ps1 files.
$ErrorActionPreference = 'Stop'
$repo = 'D:\XDU\concept\26-FPGA-Pango'
Set-Location -LiteralPath $repo
$session = Join-Path $repo ('fpga/build/route_optimization/deepseek_route_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fffffff'))
New-Item -ItemType Directory -Path $session -ErrorAction Stop | Out-Null
$build = Join-Path $repo 'fpga/build/full_integration_20261013/handoff_20261020_053147_229875'
$gatePath = Join-Path $repo 'fpga/config/implementation_readiness.json'
# Pre-launch evidence: readiness copy and git status snapshot (read-only, no cleanup).
Copy-Item -LiteralPath $gatePath -Destination (Join-Path $session 'readiness_before.json')
git -c core.fsmonitor=false status --short --untracked-files=no | Set-Content -LiteralPath (Join-Path $session 'git_status_before.txt') -Encoding UTF8
# Verify the three design gates are still true, then enable only the whole-design
# routing item. Enabling it does NOT mean timing has passed.
$gate = Get-Content -LiteralPath $gatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (!$gate.design_complete -or !$gate.selected_source_simulation_passed -or !$gate.resource_and_constraints_reviewed) { throw 'Design gates incomplete' }
$gate.whole_design_route_allowed = $true
$gate.reason = 'User instructed unlimited routing continuation (2026-10-20): seed 13 was better than seed 11 at the 90-minute cap, so restart seed 13 with no native time limit (host bound 24h) toward the burnable bitstream goal.'
$gate.updated_at = (Get-Date).ToString('o')
# The readiness file can be briefly held by system scanners as a user-mapped
# section; retry the write a few times instead of failing the whole launch.
$written = $false
for ($attempt = 0; $attempt -lt 6 -and -not $written; $attempt++) {
    try {
        [IO.File]::WriteAllText($gatePath, ($gate | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $written = $true
    } catch [System.IO.IOException] {
        Start-Sleep -Milliseconds 1500
    }
}
if (-not $written) { throw 'Readiness gate file remained locked after retries' }
$pause = Join-Path $session 'stop_requested.json'
$pythonExe = (Get-Command python -ErrorAction Stop).Source
# No --stop-after-timing: the driver gates bitgen on routed min/max STA passing,
# so a failed or stalled PnR can never reach bitgen.
$runArgs = @('-u','fpga/scripts/resume_video_system.py','--build',$build,
  '--placement-seed','13','--placement-decongestion','1',
  '--phase-timeout-minutes','1440','--pnr-timeout-minutes','0','--dump-congestion',
  '--pause-file',$pause)
# Start the driver in the background; route_supervisor inside it owns the PDS process
# via the exclusive native_phase.lock. A background process is not a Windows service:
# logoff/shutdown/hibernate can still interrupt it; keep the machine powered.
$driver = Start-Process -FilePath $pythonExe -ArgumentList $runArgs -WorkingDirectory $repo -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $session 'driver_stdout.log') `
  -RedirectStandardError (Join-Path $session 'driver_stderr.log') -PassThru
$record = [ordered]@{session=$session;build=$build;driver_pid=$driver.Id;driver_start_utc=$driver.StartTime.ToUniversalTime().ToString('o');python=$pythonExe;arguments=$runArgs;stop_file=$pause;bitstream_authorized=$true;started_at=(Get-Date).ToString('o')}
[IO.File]::WriteAllText((Join-Path $session 'launch.json'), ($record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
# Archive this launch script itself into the session dir as the round's launch record.
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $session 'launch.ps1')
$session
