# Purpose: audit the native project's single-RCF selection without editing
# project/vendor files. PDS replaces, rather than combines, multiple RCFs.
param([string]$Project='', [string]$EvidenceDirectory='')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$Project){$Project=Join-Path $taskFpga 'project/mini_raw8_geometry/mini_raw8_geometry.pds'}
$taskNative=Get-Content -LiteralPath $Project -Raw
$taskCombinedPath=Join-Path $taskFpga 'constraints/mini_raw8_dual/geometry_priority.rcf'
$taskBasePath=Join-Path $taskFpga 'constraints/mini_camera_diag/routing.rcf'
$taskCombined=Get-Content -LiteralPath $taskCombinedPath -Raw
# Count native file inputs, not comments; preserve every inherited command.
if(([regex]::Matches($taskNative,'\(_format rcf\)')).Count -ne 1 -or
   !$taskNative.Contains('geometry_priority.rcf')){throw 'Expected one combined geometry RCF'}
$taskCount=0
foreach($taskLine in (Get-Content -LiteralPath $taskBasePath)){
 if($taskLine.Trim().StartsWith('def_route ')){
  if(!$taskCombined.Contains($taskLine.Trim())){throw "Missing inherited RCF command: $taskLine"}
  $taskCount++
 }
}
if(!$taskCount){throw 'Native RCF contains no inherited route commands'}
# Optional audit evidence is confined to this project's FPGA build area.
$taskResult=[ordered]@{passed=$true;inherited_commands=$taskCount;
 combined_commands=([regex]::Matches($taskCombined,'(?m)^def_route ')).Count;
 project_sha256=(Get-FileHash -LiteralPath $Project).Hash;
 combined_rcf_sha256=(Get-FileHash -LiteralPath $taskCombinedPath).Hash;
 inherited_rcf_sha256=(Get-FileHash -LiteralPath $taskBasePath).Hash}
if($EvidenceDirectory){
 $taskEvidence=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
 $taskBuild=[IO.Path]::GetFullPath((Join-Path $taskFpga 'build'))
 if(!$taskEvidence.StartsWith($taskBuild+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
  throw 'RCF evidence must be inside FPGA build directory'
 }
 $taskResult | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskEvidence 'route_constraints_check.json') -Encoding utf8
}
Write-Output "GEOMETRY_SINGLE_RCF_CHECK_PASS inherited=$taskCount total=$($taskResult.combined_commands)"
