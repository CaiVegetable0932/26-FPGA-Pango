# Purpose: bounded offline regression of the shared main HDMI interface.
# The symbol observer deliberately does not claim physical serializer validation.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$fpgaRoot=Split-Path $PSScriptRoot -Parent
$runRoot=Join-Path $fpgaRoot ('build/hdmi_main/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
Push-Location $runRoot
try {
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE -ne 0){throw 'vlib failed'}
 $files=@('hdmi_tx_powerup_reset.v','hdmi_tx_rgb.v','tmds_encoder.v',
  'sync_vg.v','hdmi_test_pattern.v','hdmi_720p_diagnostic.v','hdmi_rgb565_expand.v') |
  ForEach-Object {Join-Path $fpgaRoot "rtl/hdmi/$_"}
 & "$ModelSimHome/vlog.exe" -sv @files (Join-Path $fpgaRoot 'sim/tb_hdmi_main.sv') 2>&1 |
  Tee-Object compile.log
 if($LASTEXITCODE -ne 0){throw 'compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_hdmi_main -do 'onerror {quit -code 2}; run -all; quit -f' 2>&1 |
  Tee-Object simulation.log
 $passed=$LASTEXITCODE -eq 0 -and (Select-String -Path simulation.log -Pattern 'HDMI_MAIN_PASS' -Quiet) -and
  !(Select-String -Path simulation.log -Pattern '\*\* (Error|Fatal)' -Quiet)
 [ordered]@{passed=$passed;scope='reset, RGB565, RGB888/control lane alignment, 720p raster';
  physical_serializer_tested=$false;hardware_tested=$false} | ConvertTo-Json |
  Set-Content result.json -Encoding utf8
 if(!$passed){throw "HDMI regression failed: $runRoot"}
 Write-Output "HDMI_MAIN_SIM_PASS $runRoot"
} finally {Pop-Location}
