# 用途：仅运行 MINI 例程适配的离线 ModelSim 回归；不调用 JTAG/PDS 下载工具。
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$fpgaRoot=Split-Path $PSScriptRoot -Parent
$simRoot=Join-Path $fpgaRoot ('build/mini_camera_diag/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $simRoot -Force | Out-Null
# 用途：从未改写的参考表提取独立黄金向量，明确丢弃四个只读 ID 占位写。
$reference=Join-Path (Split-Path $fpgaRoot -Parent) 'reference/盘古100K200K MINI开发板/2_Demo/5_1 双目摄像头例程/ov5640_200k/rtl/camera/data_init.v'
$refText=Get-Content -LiteralPath $reference -Raw -Encoding UTF8
$entries=[regex]::Matches($refText,"assign cfg_data_reg\[\s*(\d+)\] = 24'h([0-9a-fA-F]{4})_([0-9a-fA-F]{2});")
$golden=@($entries | Where-Object { [int]$_.Groups[1].Value -lt 244 } | ForEach-Object { $_.Groups[2].Value+$_.Groups[3].Value })
if($golden.Count -ne 244) { throw 'Unexpected original camera register table' }
$golden | Set-Content -LiteralPath (Join-Path $simRoot 'vendor_registers_244.hex') -Encoding ascii
Push-Location $simRoot
try {
    & "$ModelSimHome/vlib.exe" work 2>&1 | Tee-Object -FilePath library.log
    if($LASTEXITCODE -ne 0) { throw 'ModelSim library creation failed' }
    & "$ModelSimHome/vlog.exe" -sv -work work (Join-Path $fpgaRoot 'rtl/mini_camera_diag/vendor/camera/SCCB.v') (Join-Path $fpgaRoot 'rtl/mini_camera_diag/vendor/camera/data_init.v') (Join-Path $fpgaRoot 'sim/tb_mini_sccb.sv') 2>&1 | Tee-Object -FilePath compile.log
    if($LASTEXITCODE -ne 0) { throw 'ModelSim compile failed' }
    & "$ModelSimHome/vsim.exe" -c -lib ./work tb_mini_sccb -do 'onerror {quit -code 2}; run -all; quit -f' 2>&1 | Tee-Object -FilePath simulation.log
    $nativeExit=$LASTEXITCODE
    $log=Get-Content -LiteralPath simulation.log -Raw
    $passed=$nativeExit -eq 0 -and $log -match 'MINI_SCCB_PASS' -and $log -notmatch 'MINI_SCCB_FAIL|MINI_SCCB_TIMEOUT|\*\* (Error|Fatal)'
    if(!$passed) { throw "Offline regression failed: $simRoot" }
    # Purpose: independently verify the modified DVP packer, without native DDR/IP models.
    & "$ModelSimHome/vlog.exe" -sv -work work (Join-Path $fpgaRoot 'rtl/mini_camera_diag/vendor/camera/camera_data.v') (Join-Path $fpgaRoot 'sim/tb_mini_dvp.sv') 2>&1 | Tee-Object -FilePath dvp_compile.log
    if($LASTEXITCODE -ne 0) { throw 'DVP regression compile failed' }
    & "$ModelSimHome/vsim.exe" -c -lib ./work tb_mini_dvp -do 'run -all; quit -f' 2>&1 | Tee-Object -FilePath dvp_simulation.log
    $dvpExit=$LASTEXITCODE
    $dvpLog=Get-Content -LiteralPath dvp_simulation.log -Raw
    $dvpPassed=$dvpExit -eq 0 -and $dvpLog -match 'MINI_DVP_PASS' -and $dvpLog -notmatch 'MINI_DVP_FAIL|MINI_DVP_TIMEOUT|\*\* (Error|Fatal)'
    [ordered]@{run=$simRoot;sccb_passed=$passed;dvp_passed=$dvpPassed;passed=($passed -and $dvpPassed);hardware_tested=$false;programmed=$false;scope='SCCB/configuration and DVP byte alignment only'} | ConvertTo-Json | Set-Content -LiteralPath result.json -Encoding UTF8
    if(!$dvpPassed) { throw "DVP regression failed: $simRoot" }
    Write-Output "OFFLINE_CAMERA_CONTROL_PASS $simRoot"
} finally { Pop-Location }
