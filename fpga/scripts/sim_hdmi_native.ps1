# Purpose: run actual PDS OSERDES models against all 1024 repeated symbols.
# Compiled library remains read-only; vmap modifies only the new run directory.
param([string]$ModelSimHome='E:/ModelsimSE/win64', [string]$SimLibrary='')
$ErrorActionPreference='Stop'
$fpgaRoot=Split-Path $PSScriptRoot -Parent
if(!$SimLibrary){$SimLibrary=Join-Path $fpgaRoot 'build/simlib_verified'}
$runRoot=Join-Path $fpgaRoot ('build/hdmi_main/native_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
Push-Location $runRoot
try {
 & "$ModelSimHome/vmap.exe" -c
 if($LASTEXITCODE){throw 'vmap initialization failed'}
 foreach($lib in @('usim','oserdes_e2')) {
  & "$ModelSimHome/vmap.exe" $lib (Join-Path $SimLibrary $lib)
  if($LASTEXITCODE){throw 'library mapping failed'}
 }
 & "$ModelSimHome/vlib.exe" work
 if($LASTEXITCODE){throw 'vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv (Join-Path $fpgaRoot 'rtl/hdmi/hdmi_tx_oserdes.v') `
  (Join-Path $fpgaRoot 'rtl/hdmi/hdmi_tx_powerup_reset.v') `
  (Join-Path $fpgaRoot 'rtl/board/reset_sync.v') `
  (Join-Path $fpgaRoot 'sim/tb_hdmi_native.sv') 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'native test compile failed'}
 & "$ModelSimHome/vsim.exe" -c -L usim -L oserdes_e2 tb_hdmi_native `
  -do 'onerror {quit -code 2}; run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $passed=$LASTEXITCODE -eq 0 -and (Select-String simulation.log -Pattern 'TMDS_PASS' -Quiet) -and
  !(Select-String simulation.log -Pattern '\*\* (Error|Fatal)|TMDS_FAILED|TMDS_TIMEOUT' -Quiet)
 [ordered]@{passed=$passed;scope='native OSERDES repeated symbols, differential complement, reset recovery';
  hardware_tested=$false;symbols=1024} | ConvertTo-Json | Set-Content result.json -Encoding utf8
 if(!$passed){throw "Native HDMI test failed: $runRoot"}
 Write-Output "HDMI_NATIVE_PASS $runRoot"
} finally {Pop-Location}
