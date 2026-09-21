# Purpose: offline PRAW-to-Ethernet integration; no socket, UART or JTAG is opened.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/video_network_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
# Purpose: preserve exact source provenance for this offline wire-format result.
$taskInputs=@('rtl/network/praw_packetizer.v','rtl/network/udp_ipv4_eth_tx.v',
 'rtl/network/video_network_tx.v','sim/tb_video_network_tx.sv','sim/check_video_network.py') |
 ForEach-Object {Join-Path $taskFpga $_}
@($taskInputs + @($PSCommandPath,(Join-Path $taskFpga '../host/src/pango_video/protocol.py')) | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
}) | ConvertTo-Json | Set-Content (Join-Path $taskRun 'source_manifest.json') -Encoding utf8
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv (Join-Path $taskFpga 'rtl/network/praw_packetizer.v') `
  (Join-Path $taskFpga 'rtl/network/udp_ipv4_eth_tx.v') (Join-Path $taskFpga 'rtl/network/video_network_tx.v') `
  (Join-Path $taskFpga 'sim/tb_video_network_tx.sv') 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Network RTL compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_video_network_tx -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 if($LASTEXITCODE -or !(Select-String -Path simulation.log -Pattern 'VIDEO_NETWORK_PASS' -Quiet) -or
    (Select-String -Path simulation.log -Pattern 'VIDEO_NET_FAIL|VIDEO_NETWORK_TIMEOUT|\*\* (Fatal|Error)' -Quiet)){throw 'Network simulation failed'}
 python -B (Join-Path $taskFpga 'sim/check_video_network.py') $taskRun | Tee-Object result.json
 if($LASTEXITCODE){throw 'Ethernet/host interoperability failed'}
 Write-Output "VIDEO_NETWORK_INTEROP_PASS $taskRun"
} finally {Pop-Location}
