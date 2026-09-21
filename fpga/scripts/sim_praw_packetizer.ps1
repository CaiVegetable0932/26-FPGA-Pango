# Purpose: compile and simulate real PRAW RTL, then feed its bytes to the host decoder.
# All inputs are synthetic; no camera, UART, network socket or programmer is opened.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/praw_protocol_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
# Purpose: bind evidence to the exact RTL, test, checker, runner and host decoder.
$taskInputs=@('rtl/network/praw_packetizer.v','sim/tb_praw_packetizer.sv','sim/check_praw_packets.py') |
 ForEach-Object {Join-Path $taskFpga $_}
@($taskInputs + @($PSCommandPath,(Join-Path $taskFpga '../host/src/pango_video/protocol.py')) | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
}) | ConvertTo-Json | Set-Content (Join-Path $taskRun 'source_manifest.json') -Encoding utf8
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv (Join-Path $taskFpga 'rtl/network/praw_packetizer.v') (Join-Path $taskFpga 'sim/tb_praw_packetizer.sv') 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'RTL compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_praw_packetizer -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 if($LASTEXITCODE -or !(Select-String -Path simulation.log -Pattern 'PRAW_PACKETIZER_PASS' -Quiet) -or (Select-String -Path simulation.log -Pattern 'PRAW_FAIL|PRAW_TIMEOUT|\*\* (Fatal|Error)' -Quiet)){throw 'PRAW simulation failed'}
 python -B (Join-Path $taskFpga 'sim/check_praw_packets.py') $taskRun | Tee-Object result.json
 if($LASTEXITCODE){throw 'Host decoder interoperability failed'}
 Write-Output "PRAW_INTEROP_PASS $taskRun"
} finally {Pop-Location}
