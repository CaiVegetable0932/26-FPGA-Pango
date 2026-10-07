# Purpose: offline READ-select timing-contract regression; compare the default
# API with an immutable baseline, then test physical UART at two clock rates.
# Only build outputs are generated; no PDS, hardware or vendor file is touched.
param([string]$ModelSimHome='E:/ModelsimSE/win64',
 [string]$BaselineConfig='')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(-not $BaselineConfig){$BaselineConfig=Join-Path $taskFpga 'build/structural_baseline_20261006/geometry_config_bank.v'}
$BaselineConfig=(Resolve-Path -LiteralPath $BaselineConfig).Path
$taskRun=Join-Path $taskFpga ('build/geometry_config_predecode_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskSources=@(Get-ChildItem (Join-Path $taskFpga 'rtl/geometry'),(Join-Path $taskFpga 'rtl/control') -Filter '*.v' | ForEach-Object FullName)
$taskSources+=Join-Path $taskFpga 'sim/tb_geometry_config_predecode.sv'
$taskSources+=Join-Path $taskFpga 'sim/tb_geometry_config_read_uart.sv'
# Hash original inputs before deriving the renamed reference or compiling.
# The historical baseline is read-only; its generated copy lives in this run.
$taskInputs=@($taskSources)+@($PSCommandPath,$BaselineConfig)
$taskEvidence=@($taskInputs | Sort-Object -Unique | ForEach-Object {
 [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
})
[ordered]@{captured_at=(Get-Date).ToString('o');files=$taskEvidence} |
 ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskRun 'sources.json') -Encoding UTF8
$taskPrevious=$env:MODELSIM
Push-Location $taskRun
try {
 $taskReference=(Get-Content -LiteralPath $BaselineConfig -Raw) -replace '\bmodule\s+geometry_config_bank\b','module geometry_config_bank_reference'
 $taskReference | Set-Content -LiteralPath 'geometry_config_bank_reference.v' -Encoding ASCII
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 if($LASTEXITCODE){throw 'predecode vlib failed'}
 & "$ModelSimHome/vlog.exe" -sv geometry_config_bank_reference.v @taskSources 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'predecode compile failed'}
 $taskRuns=@(
  @{top='tb_geometry_config_predecode';log='default_equivalence.log';args=@();pass='CONFIG_PREDECODE_PASS'},
  @{top='tb_geometry_config_read_uart';log='uart_default.log';args=@();pass='CONFIG_READ_UART_PASS'},
  @{top='tb_geometry_config_read_uart';log='uart_125mhz.log';args=@('-gCLK_HZ=125000000');pass='CONFIG_READ_UART_PASS'}
 )
 foreach($taskCase in $taskRuns){
  $taskArguments=@('-c',$taskCase.top)+$taskCase.args+@('-do','run -all; quit -f')
  & "$ModelSimHome/vsim.exe" @taskArguments 2>&1 | Tee-Object $taskCase.log
  $taskText=Get-Content -LiteralPath $taskCase.log -Raw
  if($LASTEXITCODE -or $taskText -notmatch $taskCase.pass -or $taskText -match '\*\* (Fatal|Error)|CONFIG_.*(FAIL|TIMEOUT)'){
   throw "predecode regression failed: $($taskCase.log); $taskRun"
  }
 }
} finally {
 # Endpoint hash comparison is mandatory even after a simulation failure.
 $taskAfter=@(foreach($taskFile in $taskEvidence){
  $taskHash=(Get-FileHash -LiteralPath $taskFile.path -Algorithm SHA256).Hash
  [ordered]@{path=$taskFile.path;before_sha256=$taskFile.sha256;after_sha256=$taskHash;unchanged=($taskFile.sha256 -eq $taskHash)}
 })
 $taskUnchanged=@($taskAfter | Where-Object {-not $_.unchanged}).Count -eq 0
 [ordered]@{verified_at=(Get-Date).ToString('o');passed=$taskUnchanged;files=$taskAfter} |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskRun 'sources.verification.json') -Encoding UTF8
 $env:MODELSIM=$taskPrevious
 Pop-Location
 if(-not $taskUnchanged){throw "predecode sources changed during run: $taskRun"}
}
Write-Output "GEOMETRY_CONFIG_PREDECODE_REGRESSION_PASS $taskRun"
