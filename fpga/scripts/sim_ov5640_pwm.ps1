# 用途：离线核验新读事务/参数组/源节拍及旧 244 项初始化、DVP 回归，不访问硬件。
param(
 [ValidateSet('ModelSim','Icarus')][string]$Simulator='ModelSim',
 [string]$ModelSimHome='E:/ModelsimSE/win64',
 [string]$IcarusHome=''
)
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
if(!$IcarusHome){$IcarusHome=Join-Path $taskFpga 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'}
$taskRun=Join-Path $taskFpga ('build/ov5640_pwm_20261012/sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Force $taskRun | Out-Null
# 用途：从只读 MINI 目标板参考表提取独立黄金向量，保留既有 244 条写验证。
$taskRef=Join-Path (Split-Path $taskFpga -Parent) 'reference/盘古100K200K MINI开发板/2_Demo/5_1 双目摄像头例程/ov5640_200k/rtl/camera/data_init.v'
$taskMatches=[regex]::Matches((Get-Content -LiteralPath $taskRef -Raw -Encoding UTF8),"assign cfg_data_reg\[\s*(\d+)\] = 24'h([0-9a-fA-F]{4})_([0-9a-fA-F]{2});")
$taskGolden=@($taskMatches | Where-Object { [int]$_.Groups[1].Value -lt 244 } | ForEach-Object { $_.Groups[2].Value+$_.Groups[3].Value })
if($taskGolden.Count -ne 244){throw 'Unexpected vendor table length'}
$taskGolden | Set-Content (Join-Path $taskRun 'vendor_registers_244.hex') -Encoding ascii
Push-Location $taskRun
try {
    if($Simulator -eq 'ModelSim'){
        & "$ModelSimHome/vlib.exe" work 2>&1 | Tee-Object library.log
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    $taskSources=@('rtl/board/reset_sync.v','rtl/mini_camera_diag/vendor/camera/SCCB.v','rtl/mini_camera_diag/vendor/camera/data_init.v','rtl/mini_camera_diag/vendor/camera/camera_data.v','rtl/mini_camera_diag/vendor/camera/camera.v','rtl/mini_camera_diag/ov5640_control.v','rtl/mini_camera_diag/ov5640_timing_monitor.v','sim/ov5640_sccb_model.sv','sim/tb_mini_sccb.sv','sim/tb_mini_dvp.sv','sim/tb_ov5640_read.sv','sim/tb_ov5640_control.sv','sim/tb_ov5640_timing.sv','sim/tb_ov5640_camera.sv','sim/tb_ov5640_warmup.sv') | ForEach-Object {Join-Path $taskFpga $_}
    if($Simulator -eq 'ModelSim'){
        & "$ModelSimHome/vlog.exe" -sv -work work @taskSources 2>&1 | Tee-Object compile.log
        if($LASTEXITCODE -ne 0){throw 'vlog failed'}
    }
    $taskResults=[ordered]@{}
    foreach($taskCase in @('mini_sccb','mini_dvp','ov5640_read','ov5640_control','ov5640_timing','ov5640_camera','ov5640_camera_auto','ov5640_warmup')){
        # 用途：开源便携引擎逐顶层编译，保留每个用例的真实退出码和日志。
        if($Simulator -eq 'Icarus'){
            & "$IcarusHome/iverilog.exe" -g2012 -s "tb_$taskCase" -o "$taskCase.vvp" @taskSources 2>&1 | Tee-Object "$taskCase.compile.log"
            if($LASTEXITCODE -ne 0){throw "Icarus compile failed: $taskCase"}
            & "$IcarusHome/vvp.exe" "$taskCase.vvp" 2>&1 | Tee-Object "$taskCase.log"
        } else {
            & "$ModelSimHome/vsim.exe" -c -lib ./work "tb_$taskCase" -do 'onerror {quit -code 2}; run -all; quit -f' 2>&1 | Tee-Object "$taskCase.log"
        }
        $taskExit=$LASTEXITCODE
        $taskLog=Get-Content "$taskCase.log" -Raw
        $taskPass=$taskExit -eq 0 -and $taskLog -match ($taskCase.ToUpper()+'_PASS') -and $taskLog -notmatch '\*\* (Error|Fatal)|_FAIL|_TIMEOUT'
        $taskResults[$taskCase]=$taskPass
        if(!$taskPass){throw "Regression failed: $taskCase at $taskRun"}
    }
    # 用途：额外展开 camera 封装，验证实际初始化/控制总线仲裁的模块连接。
    if($Simulator -eq 'Icarus'){
        & "$IcarusHome/iverilog.exe" -g2012 -s camera -o camera.vvp @taskSources 2>&1 | Tee-Object camera_elaborate.log
    } else {
        & "$ModelSimHome/vsim.exe" -c -lib ./work camera -do 'quit -f' 2>&1 | Tee-Object camera_elaborate.log
    }
    if($LASTEXITCODE -ne 0){throw 'camera elaboration failed'}
    if((Test-Path camera_elaborate.log) -and (Get-Content camera_elaborate.log -Raw) -match '\*\* (Error|Fatal)'){throw 'camera elaboration diagnostics failed'}
    [ordered]@{run=$taskRun;simulator=$Simulator;cases=$taskResults;passed=$true;hardware_tested=$false;programmed=$false;optical_verified=$false} | ConvertTo-Json -Depth 5 | Set-Content result.json -Encoding UTF8
    Write-Output "OV5640_PWM_OFFLINE_PASS $taskRun"
} finally {Pop-Location}
