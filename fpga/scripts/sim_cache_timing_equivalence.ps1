# Purpose: compare the cache with its immutable pre-optimization snapshot.
# The mechanically renamed fixture and all logs stay inside fpga/build.
param([Parameter(Mandatory=$true)][string]$Baseline,
 [string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/cache_timing_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOriginal=(Resolve-Path -LiteralPath $Baseline).Path
$taskCandidate=Join-Path $taskFpga 'rtl/geometry/geometry_byte_cache.v'
if($taskOriginal -eq $taskCandidate){throw 'Independent baseline required'}
$taskGolden=Join-Path $taskRun 'geometry_byte_cache_golden.v'
$taskText=[IO.File]::ReadAllText($taskOriginal)
$taskText=$taskText.Replace('module geometry_byte_cache(','module geometry_byte_cache_golden(')
[IO.File]::WriteAllText($taskGolden,$taskText,[Text.UTF8Encoding]::new($false))
$taskSources=@($taskGolden,$taskCandidate,(Join-Path $taskFpga 'sim/tb_cache_timing_equivalence.sv'))
@($taskSources+@($taskOriginal,$PSCommandPath) | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
}) | ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
$taskOldModelsim=$env:MODELSIM;$taskPassed=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Cache miter compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_cache_timing_equivalence -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskText=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'CACHE_TIMING_EQUIVALENCE_PASS' -or
  $taskText -match 'CACHE_TIMING_FAIL|\*\* (Fatal|Error)'){throw 'Cache comparison failed'}
 foreach($taskEntry in (Get-Content sources.json -Raw | ConvertFrom-Json)){
  if((Get-FileHash -LiteralPath $taskEntry.path).Hash -ne $taskEntry.sha256){throw 'Source drift'}
 }
 $taskPassed=$true
} finally {
 [ordered]@{equivalence_passed=$taskPassed;formal_proof=$false;hardware_tested=$false} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
Write-Output "CACHE_TIMING_PASS $taskRun"
