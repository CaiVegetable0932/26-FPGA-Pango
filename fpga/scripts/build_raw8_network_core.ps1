# Purpose: native offline component check only; never program or claim board STA.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',
 [ValidateSet('compile','synthesize')][string]$Stage='synthesize')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_network_core/native_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$taskImpl=Join-Path $taskFpga 'build/raw8_network_core/implementation'
$taskProject=Join-Path $taskFpga 'project/raw8_network_core/raw8_network_core.pds'
New-Item -ItemType Directory -Path $taskRun,$taskImpl -Force | Out-Null
# Purpose: retain source provenance before PDS parses a component, and restore
# its declared output directory after native saving changes it to a local dot.
$taskSources=@('rtl/raw8_dual/raw8_network_output.v','rtl/raw8_dual/raw8_unpack.v',
 'rtl/network/praw_packetizer.v','rtl/network/udp_ipv4_eth_tx.v','rtl/network/video_network_tx.v',
 'project/raw8_network_core/raw8_network_core.tcl','constraints/raw8_network_core.fdc') |
 ForEach-Object {Join-Path $taskFpga $_}
@($taskSources | ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
 ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
function Restore-Raw8ComponentLayout {
 $taskText=Get-Content -LiteralPath $taskProject -Raw
 $taskOld='(_option prj_impl_dir (_string "."))'
 $taskNew='(_option prj_impl_dir (_string "../../build/raw8_network_core/implementation"))'
 if($taskText.Contains($taskOld)){
  $taskText.Replace($taskOld,$taskNew) | Set-Content -LiteralPath $taskProject -Encoding utf8
 } elseif(!$taskText.Contains($taskNew)){throw 'Unexpected native component directory syntax'}
}
Push-Location $taskRun
try {
 & "$PdsHome/bin/pds_shell.exe" -file (Join-Path $PSScriptRoot 'create_raw8_network_core.tcl') -work_dir $taskRun 2>&1 | Tee-Object generation.log
 if($LASTEXITCODE -or !(Select-String -Path generation.log -Pattern RAW8_NATIVE_COMPONENT_GENERATED -Quiet)){
  throw 'Native component project generation failed'
 }
 Restore-Raw8ComponentLayout
 $taskBegin=Get-Date
 & "$PdsHome/bin/pds_shell.exe" -project $taskProject -work_dir $taskImpl -run $Stage 2>&1 | Tee-Object "$Stage.log"
 $taskExit=$LASTEXITCODE
 Restore-Raw8ComponentLayout
 $taskLog=Get-Content "$Stage.log" -Raw
 $taskExt=if($Stage -eq 'compile'){'cmr'}else{'snr'}
 $taskStageDir=if($Stage -eq 'compile'){'compile'}else{'synthesize'}
 $taskReports=@(Get-ChildItem (Join-Path $taskImpl $taskStageDir) -Filter "*.$taskExt" |
  Where-Object LastWriteTime -ge $taskBegin)
 $taskPass=$taskExit -eq 0 -and $taskLog -notmatch '(?m)^E:|Check license failed' -and $taskReports.Count -gt 0
 [ordered]@{stage=$Stage;passed=$taskPass;scope='RAW8 network endpoint only';
  board_top_integrated=$false;board_timing_verified=$false;programmed=$false} |
  ConvertTo-Json | Tee-Object result.json
 if(!$taskPass){throw 'Native RAW8 component stage incomplete'}
} finally {Pop-Location}
