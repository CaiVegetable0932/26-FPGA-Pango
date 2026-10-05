# Purpose: exact multiplier regression isolated from board hardware and PDS.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/geometry_mul_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
$taskPrevious=$env:MODELSIM
Push-Location $taskRun
try {
 $env:MODELSIM=$null
 & "$ModelSimHome/vmap.exe" -c | Out-Null
 $env:MODELSIM=Join-Path $taskRun 'modelsim.ini'
 & "$ModelSimHome/vlib.exe" work | Out-Null
 & "$ModelSimHome/vlog.exe" -sv (Join-Path $taskFpga 'rtl/geometry/geometry_mul_pipe.v') (Join-Path $taskFpga 'sim/tb_geometry_mul_pipe.sv') 2>&1 | Tee-Object compile.log
 if($LASTEXITCODE){throw 'Multiplier compile failed'}
 & "$ModelSimHome/vsim.exe" -c tb_geometry_mul_pipe -do 'run -all; quit -f' 2>&1 | Tee-Object simulation.log
 $taskText=Get-Content simulation.log -Raw
 if($LASTEXITCODE -or $taskText -notmatch 'GEOMETRY_MUL_PASS' -or $taskText -match 'MUL_FAIL|MUL_TIMEOUT|\*\* (Fatal|Error)'){throw 'Multiplier regression failed'}
 Write-Output "GEOMETRY_MUL_REGRESSION_PASS $taskRun"
} finally {$env:MODELSIM=$taskPrevious;Pop-Location}
