# Purpose: reproduce original/candidate ADS synthesis in isolated directories,
# and prove all 96 scratch bits changed from CE registers to non-CE registers.
# This is a structural probe, NOT STA: no clocks/I/O timing are constrained,
# and neither whole-board implementation nor placement/routing is requested.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$ExistingRun='')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskReference=Join-Path $taskFpga 'sim/candidates/geometry_marker_divide_reference_20261007.v'
$taskCandidate=Join-Path $taskFpga 'rtl/geometry/geometry_marker_divide.v'
$taskTcl=Join-Path $PSScriptRoot 'synth_geometry_marker_divide_probe.tcl'
if((Get-FileHash $taskReference).Hash -ne '44D7CC0F7BDD4B4977DAB67BAB0AEEE73E494391BCBE53FD93159DDCACB0A8B5'){throw 'Original reference changed'}
# ExistingRun performs read-only netlist inspection and adds its report only;
# the default executes both native probes before applying the same checks.
if($ExistingRun){$taskRun=(Resolve-Path $ExistingRun).Path}
else {
 $taskRun=Join-Path $taskFpga ('build/marker_divider_probe_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
 New-Item -ItemType Directory -Path $taskRun | Out-Null
}
$taskBuildRoot=[IO.Path]::GetFullPath((Join-Path $taskFpga 'build'))+[IO.Path]::DirectorySeparatorChar
if(![IO.Path]::GetFullPath($taskRun).StartsWith($taskBuildRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Probe reports must stay under fpga/build'}
$taskManifest=@(@($taskReference,$taskCandidate,$taskTcl,$PSCommandPath) | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}})
$taskOldImpl=$env:MARKER_DIVIDE_IMPL;$taskOldSource=$env:MARKER_DIVIDE_SOURCE
$taskEvidence=@()
try {
 foreach($taskVariant in @('reference','candidate')){
  $env:MARKER_DIVIDE_IMPL=Join-Path $taskRun $taskVariant
  $env:MARKER_DIVIDE_SOURCE=if($taskVariant -eq 'reference'){$taskReference}else{$taskCandidate}
  if(!$ExistingRun){
   New-Item -ItemType Directory -Path $env:MARKER_DIVIDE_IMPL | Out-Null
   & "$PdsHome/bin/pds_shell.exe" -file $taskTcl -work_dir $env:MARKER_DIVIDE_IMPL 2>&1 | Tee-Object (Join-Path $env:MARKER_DIVIDE_IMPL 'probe.log')
   if($LASTEXITCODE){throw "Native synthesis failed: $taskVariant"}
  }
  $taskNetlist=Join-Path $env:MARKER_DIVIDE_IMPL 'synthesize/geometry_marker_divide_syn.vm'
  $taskVm=Get-Content $taskNetlist -Raw
  $taskRegisters=[regex]::Matches($taskVm,'(?ms)^\s*(GTP_DFF\w*)\s*/\*\s*\\bits\[(\d+)\]\s*\*/.*?;')
  if($taskRegisters.Count -ne 96){throw "Expected 96 named bits registers: $taskVariant"}
  $taskDetails=@($taskRegisters | ForEach-Object {
   [pscustomobject][ordered]@{index=[int]$_.Groups[2].Value;primitive=$_.Groups[1].Value;has_ce_port=($_.Value -match '\.CE\s*\(')}
  } | Sort-Object index)
  for($taskIndex=0;$taskIndex -lt 96;$taskIndex++){
   if($taskDetails[$taskIndex].index -ne $taskIndex){throw 'Missing or duplicated scratch bit'}
   if($taskVariant -eq 'candidate' -and ($taskDetails[$taskIndex].primitive -ne 'GTP_DFF_C' -or $taskDetails[$taskIndex].has_ce_port)){throw 'Candidate still has scratch CE'}
   if($taskVariant -eq 'reference' -and !$taskDetails[$taskIndex].has_ce_port){throw 'Original scratch CE expectation not reproduced'}
  }
  $taskSnr=Get-Content (Join-Path $env:MARKER_DIVIDE_IMPL 'synthesize/geometry_marker_divide.snr') -Raw
  $taskEvidence+=[ordered]@{variant=$taskVariant;netlist=$taskNetlist;netlist_sha256=(Get-FileHash $taskNetlist).Hash;
   bits_register_count=96;bits_ce_count=@($taskDetails | Where-Object has_ce_port).Count;
   lut_count=[int][regex]::Match($taskSnr,'Total LUTs:\s*(\d+)').Groups[1].Value;
   ff_count=[int][regex]::Match($taskSnr,'Total Registers:\s*(\d+)').Groups[1].Value;registers=$taskDetails}
 }
 foreach($taskInput in $taskManifest){if((Get-FileHash $taskInput.path).Hash -ne $taskInput.sha256){throw 'Probe source drift'}}
 [ordered]@{structural_check_passed=$true;native_synthesis_completed=$true;pnr_run=$false;timing_verified=$false;
  existing_run_inspection=[bool]$ExistingRun;source_manifest=$taskManifest;variants=$taskEvidence} |
  ConvertTo-Json -Depth 8 | Set-Content (Join-Path $taskRun 'structure_result.json') -Encoding utf8
 Write-Output "MARKER_DIVIDER_STRUCTURE_PASS $taskRun"
} finally {$env:MARKER_DIVIDE_IMPL=$taskOldImpl;$env:MARKER_DIVIDE_SOURCE=$taskOldSource}
