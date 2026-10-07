# Purpose: isolate the UART address-only metadata decoder and its live-data
#/CDC equivalence from unrelated ongoing RTL work. No board or PDS access.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/view_predecode_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@('geometry_view_snapshot.v','geometry_view_control.v','geometry_marker_catalog.v','geometry_marker_overlay.v') |
 ForEach-Object {Join-Path $taskFpga "rtl/geometry/$_"}
$taskSources+=Join-Path $taskFpga 'sim/tb_geometry_view.sv'
$taskEvidence=@($taskSources+@($PSCommandPath) | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
})
$taskEvidence | ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
$taskOldModelsim=$env:MODELSIM;$taskPassed=$false;$taskUnchanged=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'View predecode compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_geometry_view -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskLog=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskLog -notmatch 'GEOMETRY_VIEW_PASS.*predecode_checks=.*fresh_reads=' -or
  $taskLog -match '\*\* (Fatal|Error)|VIEW_(FAIL|TIMEOUT)'){throw 'View predecode regression failed'}
 $taskPassed=$true
} finally {
 # Bind simulation evidence to the exact tested implementation and miter.
 $taskUnchanged=$true
 foreach($taskEntry in $taskEvidence){
  if((Get-FileHash -LiteralPath $taskEntry.path).Hash -ne $taskEntry.sha256){$taskUnchanged=$false}
 }
 [ordered]@{passed=($taskPassed -and $taskUnchanged);source_inputs_unchanged=$taskUnchanged;
  formal_proof=$false;hardware_tested=$false} | ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
if(!$taskUnchanged){throw 'View predecode inputs changed'}
Write-Output "GEOMETRY_VIEW_PREDECODE_PASS $taskRun"
