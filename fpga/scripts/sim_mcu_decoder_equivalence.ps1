# Purpose: compare an isolated protocol candidate against a frozen local RTL
# snapshot; outputs are offline evidence, not a claim of physical timing closure.
param([Parameter(Mandatory=$true)][string]$BaselineProtocol,
 [Parameter(Mandatory=$true)][string]$CandidateProtocol,
 [string]$CandidateQueue='',
 [string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mcu_decoder_equivalence_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
# Purpose: require an explicit frozen baseline so later integration cannot
# silently turn this regression into a candidate-versus-itself comparison.
$taskOriginal=(Resolve-Path -LiteralPath $BaselineProtocol).Path
$taskCandidate=(Resolve-Path -LiteralPath $CandidateProtocol).Path
$taskQueue=if($CandidateQueue){(Resolve-Path -LiteralPath $CandidateQueue).Path}else{''}
if($taskOriginal -eq $taskCandidate){throw 'Baseline must be an independent snapshot'}
$taskGolden=Join-Path $taskRun 'mcu_protocol_golden.v'
# Mechanical module rename only: never hand-edit the golden response logic.
$taskText=[IO.File]::ReadAllText($taskOriginal)
$taskText=[regex]::Replace($taskText,'\bmodule mcu_protocol\b','module mcu_protocol_golden')
[IO.File]::WriteAllText($taskGolden,$taskText,[Text.UTF8Encoding]::new($false))
$taskSources=@('mcu_uart_rx.v','mcu_uart_tx.v','mcu_frame_rx.v','mcu_frame_tx.v') |
 ForEach-Object {Join-Path $taskFpga "rtl/control/$_"}
$taskSources+=@($taskGolden,$taskCandidate,
 (Join-Path $taskFpga 'sim/tb_mcu_decoder_equivalence.sv'))
# A private queue may be bundled in the protocol source to preserve older PDS
# file lists. Isolated candidates may still supply it as a separate RTL file.
if($taskQueue){$taskSources+=$taskQueue}
$taskOldModelsim=$env:MODELSIM;$taskPassed=$false
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'vlib failed'}
 @($taskSources+@($taskOriginal,$PSCommandPath) | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
  ConvertTo-Json | Set-Content sources.json -Encoding utf8
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Decoder miter compile failed'}
 # Purpose: independently toggle all three diagnostic capability bits so a
 # misplaced capability guard cannot hide behind all-on/all-off test cases.
 foreach($taskGeom in @(0,1)){foreach($taskFeatures in 0..7){
  $taskLogName="geometry_${taskGeom}_features_${taskFeatures}.log"
  & "$ModelSimHome/vsim.exe" -c tb_mcu_decoder_equivalence "-gGEOM=$taskGeom" "-gFEATURES=$taskFeatures" -do 'run -all; quit -f' 2>&1 | Tee-Object $taskLogName
  $taskLog=Get-Content $taskLogName -Raw
  if($LASTEXITCODE -or $taskLog -notmatch 'MCU_DECODER_EQUIVALENCE_PASS' -or
   $taskLog -match '\*\* (Fatal|Error)|MCU_DECODER_FAIL'){throw 'Decoder miter failed'}
 }}
 foreach($taskInput in (Get-Content sources.json -Raw | ConvertFrom-Json)){
  if((Get-FileHash $taskInput.path).Hash -ne $taskInput.sha256){throw 'Source drift'}
 }
 $taskPassed=$true
} finally {
 [ordered]@{equivalence_passed=$taskPassed;formal_proof=$false;hardware_tested=$false} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
Write-Output "MCU_DECODER_MITER_PASS $taskRun"
