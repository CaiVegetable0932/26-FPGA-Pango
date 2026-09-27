# Purpose: validate RAW8 gray -> RGB -> TMDS at full 1080p raster dimensions.
# Serializer is a symbol observer; physical signaling requires board evidence.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_tmds_sim_'+(Get-Date -Format yyyyMMdd_HHmmss_fff))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@('rtl/raw8_dual/raw8_hdmi_timing.v','rtl/hdmi/tmds_encoder.v',
 'rtl/hdmi/hdmi_tx_rgb.v','sim/tb_raw8_tmds.sv') | ForEach-Object {Join-Path $taskFpga $_}
@($taskSources | ForEach-Object {@{path=$_;sha256=(Get-FileHash $_).Hash}}) |
 ConvertTo-Json | Set-Content (Join-Path $taskRun 'sources.json') -Encoding utf8
Push-Location $taskRun
try {
 & "$ModelSimHome/vlib.exe" work
 & "$ModelSimHome/vlog.exe" -sv @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'TMDS compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_raw8_tmds -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskText=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'RAW8_TMDS_PASS' -or
  $taskText -match 'RAW8_TMDS_FAIL|RAW8_TMDS_TIMEOUT|\*\* (Fatal|Error)'){throw 'TMDS regression failed'}
 Write-Output "RAW8_TMDS_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
