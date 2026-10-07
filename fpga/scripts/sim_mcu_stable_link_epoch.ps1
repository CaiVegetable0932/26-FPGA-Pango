# Purpose: immutable UART-pin stable-link-epoch proof, no PDS/hardware or RTL edits.
# Every invocation creates a fresh attempt; failures and their logs are never reused.
param([string]$ModelSimHome='E:/ModelsimSE/win64',
 [string]$GoldenDirectory='',
 [ValidateSet('all','full','clock125')][string]$Configuration='all')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$GoldenDirectory){$GoldenDirectory=Join-Path $taskFpga 'build/mcu_stable_epoch_proof_20261007_144143_995'}
$taskGolden=Join-Path $GoldenDirectory 'mcu_protocol.old.v'
$taskFixture=Join-Path $GoldenDirectory 'mcu_protocol_golden.v'
$taskCandidate=Join-Path $taskFpga 'rtl/control/mcu_protocol.v'
$taskBoard=Join-Path $taskFpga 'rtl/board/mini_raw8_geometry.v'
if((Get-FileHash $taskGolden).Hash -ne 'A0110F5AD0795FC29AF2A492087A0C8C458C27E77A253860576CE8B975EB8104'){throw 'Exact old golden required'}
if((Get-FileHash $taskCandidate).Hash -ne '47FB9B886CA67790124F96E4BDEFA1EA08C29B6509A2C6001611BBCBA8ED057D'){throw 'Authorized candidate not ready or changed'}
# Bind the reviewed physical Top after its Ethernet clock-buffer branch change.
# MCU commissioned reset/STABLE1 wiring is unchanged; Top is contract-only and
# is deliberately excluded from the eight UART-miter compile inputs below.
if((Get-FileHash $taskBoard).Hash -ne '39EAC934A1718849B0A37CE2D5D3D42E040736A4EE1A830045A5743C99D19A53'){throw 'Board premise source changed'}
$taskOldText=Get-Content $taskGolden -Raw
$taskNewText=Get-Content $taskCandidate -Raw
$taskFixtureText=Get-Content $taskFixture -Raw
if($taskOldText.Replace('module mcu_protocol #(','module mcu_protocol_golden #(').Replace("`r`n","`n").TrimEnd() -cne $taskFixtureText.Replace("`r`n","`n").TrimEnd()){throw 'Golden fixture must rename top only'}
# Both fixtures retain the identically shared queue helper. Refuse any helper drift.
if(($taskOldText -split 'module mcu_reply_queue_ram',2)[1].Replace("`r`n","`n").TrimEnd() -cne ($taskNewText -split 'module mcu_reply_queue_ram',2)[1].Replace("`r`n","`n").TrimEnd()){throw 'Shared queue helper changed'}
if($taskNewText -notmatch 'parameter integer STABLE_LINK_EPOCH = 0' -or $taskNewText -notmatch '!STABLE_LINK_EPOCH && \(link_epoch != observed_epoch\)'){throw 'Legacy default comparison missing'}
$taskRun=Join-Path $GoldenDirectory ('attempt_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $taskRun|Out-Null
$taskSourceDir=Join-Path $taskRun 'sources';New-Item -ItemType Directory -Path $taskSourceDir|Out-Null
$taskPaths=@($taskGolden,$taskFixture,$taskCandidate,$taskBoard,$PSCommandPath,(Join-Path $taskFpga 'sim/tb_mcu_stable_link_epoch.sv'))
$taskPaths+=@('comms_boot_config.v','mcu_uart_rx.v','mcu_uart_tx.v','mcu_frame_rx.v','mcu_frame_tx.v')|ForEach-Object {Join-Path $taskFpga ('rtl/control/'+$_)}
$taskEvidence=@(foreach($taskPath in $taskPaths){
 $taskCopy=Join-Path $taskSourceDir (Split-Path $taskPath -Leaf)
 Copy-Item -LiteralPath $taskPath -Destination $taskCopy
 $taskHash=(Get-FileHash -LiteralPath $taskPath).Hash
 if((Get-FileHash -LiteralPath $taskCopy).Hash -ne $taskHash){throw 'Snapshot race'}
 [ordered]@{path=$taskPath;frozen=$taskCopy;sha256=$taskHash;bytes=(Get-Item $taskCopy).Length}
})
$taskManifest=Join-Path $taskRun 'source_manifest.json'
[ordered]@{schema='mcu-stable-epoch-source.v1';captured_before_compile=$true;golden_top_rename_only=$true;shared_helper_identical=$true;files=$taskEvidence}|ConvertTo-Json -Depth 5|Set-Content $taskManifest -Encoding UTF8
$taskManifestHash=(Get-FileHash $taskManifest).Hash
$taskResult=[ordered]@{passed=$false;source_manifest_sha256=$taskManifestHash;runs=@();formal_proof=$false;pds_run=$false;hardware_tested=$false}
$taskPriorModelSim=$env:MODELSIM
Push-Location $taskRun
try{
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c 2>&1|Tee-Object vmap.log
 if($LASTEXITCODE){throw 'vmap failed'}
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work 2>&1|Tee-Object vlib.log
 if($LASTEXITCODE){throw 'vlib failed'}
 $taskNames=@('mcu_uart_rx.v','mcu_uart_tx.v','mcu_frame_rx.v','mcu_frame_tx.v','comms_boot_config.v','mcu_protocol_golden.v','mcu_protocol.v','tb_mcu_stable_link_epoch.sv')
 $taskCompile=@($taskNames|ForEach-Object {Join-Path $taskSourceDir $_})
 & "$ModelSimHome/vlog.exe" -sv @taskCompile 2>&1|Tee-Object compile.log
 if($LASTEXITCODE){throw 'Compile failed'}
 $taskCases=@(@{name='full';hz=1843200;full=1},@{name='clock125';hz=125000000;full=0})
 foreach($taskCase in $taskCases){
  if($Configuration -ne 'all' -and $Configuration -ne $taskCase.name){continue}
  $taskArgs=@('-c','tb_mcu_stable_link_epoch',("-gCLK_HZ="+$taskCase.hz),("-gFULL="+$taskCase.full),'-voptargs=+acc','-wlf',($taskCase.name+'.wlf'),'-l',($taskCase.name+'_transcript.log'),'-do','onerror {quit -code 2}; onbreak {quit -code 2}; run -all; quit -f')
  & "$ModelSimHome/vsim.exe" @taskArgs 2>&1|Tee-Object ($taskCase.name+'.log')
  $taskExit=$LASTEXITCODE;$taskLog=Get-Content ($taskCase.name+'.log') -Raw
  $taskPass=$taskExit -eq 0 -and $taskLog -match 'MCU_STABLE_EPOCH_PASS' -and $taskLog -notmatch '\*\* (Error|Fatal)|MCU_STABLE_EPOCH_FAIL|TIMEOUT'
  $taskResult.runs+=[ordered]@{name=$taskCase.name;clock_hz=$taskCase.hz;baud=115200;full=[bool]$taskCase.full;plus_acc=$true;exit_code=$taskExit;passed=$taskPass;log=($taskCase.name+'.log');log_sha256=(Get-FileHash ($taskCase.name+'.log')).Hash}
  if(!$taskPass){throw ('UART miter failed: '+$taskCase.name)}
 }
 $taskResult.passed=$true
}finally{
 # Always recheck live and frozen sources and preserve a failure result per attempt.
 $taskChecks=@(foreach($taskItem in $taskEvidence){[ordered]@{path=$taskItem.path;frozen=$taskItem.frozen;expected=$taskItem.sha256;live=(Get-FileHash $taskItem.path).Hash;snapshot=(Get-FileHash $taskItem.frozen).Hash}})
 $taskUnchanged=@($taskChecks|Where-Object {$_.expected -ne $_.live -or $_.expected -ne $_.snapshot}).Count -eq 0 -and (Get-FileHash $taskManifest).Hash -eq $taskManifestHash
 $taskResult.sources_unchanged=$taskUnchanged;if(!$taskUnchanged){$taskResult.passed=$false}
 $taskResult.finished=(Get-Date).ToString('o')
 $taskChecks|ConvertTo-Json -Depth 4|Set-Content source_verification.json -Encoding UTF8
 $taskResult|ConvertTo-Json -Depth 6|Set-Content result.json -Encoding UTF8
 $env:MODELSIM=$taskPriorModelSim;Pop-Location
 Write-Output ("MCU_STABLE_EPOCH_RESULT "+$taskRun+" passed="+$taskResult.passed)
}
if(!$taskResult.passed){throw 'Stable epoch proof failed'}

