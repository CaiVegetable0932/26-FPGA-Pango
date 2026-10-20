# Whole-design routing launch, user-assigned bitstream-goal rounds (updated 2026-10-20 14:40).
# Purpose: after the section 5 preflight (source/MAP/PCF SHA + readiness gates) passes,
#          enable the whole-design routing gate and start the background driver for
#          PnR + min/max STA, then bitgen when STA passes (full burnable bitstream goal).
# History: round 1 (seed 11) used --stop-after-timing and is archived in
#          deepseek_route_20261020_125517_1325705. Seed 7 failed placement twice
#          (Place-0006 DDR PHY OSERDES at ~150s, even in a clean directory), so
#          this version returns to seed 11, which completed placement and routed
#          for the full 60 minutes in round 1. Bitgen enabled after successful STA.
# Hard constraints (do not change):
#   - bitgen only runs inside the driver after routed min/max STA reports
#     "All Constraints Met"; no standalone bypass, no JTAG download or board burn;
#   - fixed --placement-seed / --placement-decongestion 1; no seed sweep, no extra knobs;
#   - host allowance 90 minutes per native phase (--phase-timeout-minutes 90,
#     user-instructed 1.5h single-routing timeout on 2026-10-20);
#   - exactly one PDS executor; frozen sources/MAP/PCF/timing constraints untouched;
#   - the stop file is only recorded as a path, never pre-created (an existing file
#     makes the supervisor treat the launch as a pause request).
# Note: this file is intentionally pure ASCII because Windows PowerShell 5.1 reads
# BOM-less .ps1 files as ANSI and would misparse non-ASCII comment bytes.
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
$gate.reason = 'User assigned the bitstream-goal routing effort (2026-10-20): seed 7 proven to fail placement twice (Place-0006), so return to seed 11 with the 1.5-hour single-routing timeout; bitgen enabled after routed min/max STA passes.'
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
# so a failed or timed-out PnR can never reach bitgen.
$runArgs = @('-u','fpga/scripts/resume_video_system.py','--build',$build,
  '--placement-seed','11','--placement-decongestion','1',
  '--phase-timeout-minutes','90','--pnr-timeout-minutes','90','--dump-congestion',
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
