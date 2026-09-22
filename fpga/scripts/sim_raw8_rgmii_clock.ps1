# Purpose: native GTP-only regression for free-running PHY TXC and data reset.
# Official models are read-only; all compiled objects stay in a fresh run.
param([string]$PdsHome='E:/PDS_Pangu/PDS_2022.2-SP6.4',[string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/raw8_rgmii_clock_'+(Get-Date -Format yyyyMMdd_HHmmss_fff))
$taskInputs=@((Join-Path $PdsHome 'arch/vendor/pango/verilog/simulation/GTP_GRS.v'),
 (Join-Path $PdsHome 'arch/vendor/pango/verilog/simulation/GTP_ODDR_E1.v'),
 (Join-Path $taskFpga 'rtl/network/pango_rgmii_tx.v'),(Join-Path $taskFpga 'sim/tb_raw8_rgmii_clock.sv'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskOld=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c
 if($LASTEXITCODE){throw 'vmap failed'}
 $env:MODELSIM=Join-Path $taskRun modelsim.ini
 & "$ModelSimHome/vlib.exe" work
 & "$ModelSimHome/vlog.exe" -sv @taskInputs 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'native compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_raw8_rgmii_clock -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 if($LASTEXITCODE -or !(Select-String simulation.log -Pattern RAW8_RGMII_CLOCK_PASS -Quiet) -or
    (Select-String simulation.log -Pattern '\*\* (Fatal|Error)|RAW8_RGMII_FAIL|RAW8_RGMII_TIMEOUT' -Quiet)){throw 'clock regression failed'}
 [ordered]@{passed=$true;vectors=1024;local_resets=4;native_gtp_models=$true;hardware_tested=$false;
  sources=@($taskInputs|ForEach-Object {[ordered]@{path=$_;sha256=(Get-FileHash $_).Hash}})} |
  ConvertTo-Json -Depth 4 | Set-Content result.json -Encoding utf8
 Write-Output "RAW8_RGMII_NATIVE_PASS $taskRun"
} finally {$env:MODELSIM=$taskOld;Pop-Location}
