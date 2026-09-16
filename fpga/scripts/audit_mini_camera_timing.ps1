# Purpose: distinguish PDS command completion from actual constraint closure.
# This audit reads only the diagnostic report and never enables programming.
param([switch]$ReportOnly)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskReport=Join-Path $taskFpga 'build/mini_camera_diag/implementation/report_timing/Top.rtr'
$taskText=Get-Content -LiteralPath $taskReport -Raw
$taskSummary=[regex]::Match($taskText,'(?m)^Design Summary\s*:\s*(.+)$').Groups[1].Value.Trim()
# Purpose: unknown native summary wording fails closed; no "exit 0 means pass".
$taskViolated=$taskSummary -eq 'Some Constraints Violated.'
$taskMet=$taskSummary -eq 'All Constraints Met.'
$taskRows=[Collections.Generic.List[object]]::new()
$taskSection=''
foreach($taskLine in ($taskText -split "\r?\n")){
 if($taskLine -match '^(Setup|Hold|Recovery|Removal) Summary\((Slow|Fast) Corner\):'){
  $taskSection=$Matches[1]+'_'+$Matches[2]
 } elseif($taskLine -match '^Minimum Pulse Width Summary'){ $taskSection='' }
 elseif($taskLine -match '^Slow Corner$'){break}
 elseif($taskSection -and $taskLine -match '^\s+(\S+)\s+(\S+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$'){
  $taskRows.Add([pscustomobject]@{section=$taskSection;launch=$Matches[1];capture=$Matches[2];
   slack_ns=[double]::Parse($Matches[3],[Globalization.CultureInfo]::InvariantCulture);
   failing_endpoints=[int]$Matches[5]})
 }
}
$taskResult=[ordered]@{report=$taskReport;sha256=(Get-FileHash $taskReport -Algorithm SHA256).Hash;
 checked_at=(Get-Date).ToString('o');design_summary=$taskSummary;constraints_violated=$taskViolated;
 timing_constraints_met=$taskMet;external_timing_verified=$false;release_ready=$false;
 hardware_tested=$false;programmed=$false;clock_pair_summaries=$taskRows}
$taskResult | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $taskFpga 'build/mini_camera_diag/timing_audit.json') -Encoding utf8
Write-Output "TIMING_AUDIT constraints_met=$taskMet summary=$taskSummary"
if(!$taskMet -and !$ReportOnly){throw 'Diagnostic timing is not closed; inspect timing_audit.json'}
