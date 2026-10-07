# Purpose: compare reply capture timing with a frozen pre-optimization module.
# Rename both the wrapper and private RAM helper only in generated fixtures.
param([Parameter(Mandatory=$true)][string]$Baseline,
 [string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/mcu_snapshot_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOriginal=(Resolve-Path -LiteralPath $Baseline).Path
$taskCandidate=Join-Path $taskFpga 'rtl/control/mcu_protocol.v'
if($taskOriginal -eq $taskCandidate){throw 'Independent baseline required'}
$taskGolden=Join-Path $taskRun 'mcu_protocol_golden.v'
$taskText=[IO.File]::ReadAllText($taskOriginal)
$taskText=[regex]::Replace($taskText,'\bmodule mcu_protocol\b','module mcu_protocol_golden')
$taskText=[regex]::Replace($taskText,'\bmcu_reply_queue_ram\b','mcu_reply_queue_ram_golden')
[IO.File]::WriteAllText($taskGolden,$taskText,[Text.UTF8Encoding]::new($false))
$taskSources=@('mcu_uart_rx.v','mcu_uart_tx.v','mcu_frame_rx.v','mcu_frame_tx.v') |
 ForEach-Object {Join-Path $taskFpga "rtl/control/$_"}
$taskSources+=@($taskGolden,$taskCandidate,(Join-Path $taskFpga 'sim/tb_mcu_snapshot_timing.sv'))
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
 if($LASTEXITCODE){throw 'Snapshot miter compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_mcu_snapshot_timing -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskText=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'SNAPSHOT_TIMING_PASS' -or
  $taskText -match 'SNAPSHOT_TIMING_FAIL|\*\* (Fatal|Error)'){throw 'Snapshot comparison failed'}
 foreach($taskEntry in (Get-Content sources.json -Raw | ConvertFrom-Json)){
  if((Get-FileHash -LiteralPath $taskEntry.path).Hash -ne $taskEntry.sha256){throw 'Source drift'}
 }
 $taskPassed=$true
} finally {
 [ordered]@{equivalence_passed=$taskPassed;formal_proof=$false;hardware_tested=$false} |
  ConvertTo-Json | Set-Content result.json -Encoding utf8
 $env:MODELSIM=$taskOldModelsim;Pop-Location
}
Write-Output "MCU_SNAPSHOT_PASS $taskRun"
