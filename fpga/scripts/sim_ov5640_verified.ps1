# Purpose: reproducible regression for verified camera startup and RGB565 capture.
# Native ModelSim output stays under fpga/build; FAIL/Fatal/Timeout is an error
# even if this ModelSim version returns exit code zero after a Verilog $fatal.
param([string]$ModelSimHome='E:/ModelsimSE/win64')
$ErrorActionPreference='Stop'
$taskFpga=Split-Path $PSScriptRoot -Parent
$taskRun=Join-Path $taskFpga ('build/camera_verified_sim_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $taskRun | Out-Null
Push-Location $taskRun
try {
    & "$ModelSimHome/vlib.exe" work
    if($LASTEXITCODE){throw 'vlib failed'}
    $taskSources=@('rtl/mini_camera_diag/ov5640_sccb.v','rtl/mini_camera_diag/ov5640_startup.v',
        'rtl/mini_camera_diag/vendor/camera/data_init.v','rtl/mini_camera_diag/vendor/camera/camera_data.v',
        'rtl/mini_camera_diag/mini_dvp_observe.v','rtl/mini_camera_diag/mini_dvp_input.v',
        'rtl/mini_camera_diag/mini_dvp_measure.v','rtl/mini_camera_diag/mini_diag_snapshot.v',
        'rtl/mini_camera_diag/mini_diag_raster.v','sim/tb_dvp_measure.sv',
        'sim/tb_capture_status.sv','sim/tb_ov5640_verified_startup.sv',
        'sim/tb_ov5640_startup_timing.sv','sim/tb_mini_dvp.sv','sim/tb_camera_warmup_audit.sv',
        'sim/tb_dvp_boundary.sv','sim/tb_dvp_vsync_closes_line.sv','rtl/board/reset_sync.v',
        'rtl/mini_camera_diag/vendor/camera/camera.v','sim/tb_camera_startup_audit.sv') |
        ForEach-Object {Join-Path $taskFpga $_}
    & "$ModelSimHome/vlog.exe" -work work @taskSources
    if($LASTEXITCODE){throw 'vlog failed'}
    foreach($taskTop in @('tb_ov5640_sccb_read','tb_ov5640_verified_startup','tb_ov5640_startup_timing',
                          'tb_mini_dvp','tb_camera_warmup_audit','tb_dvp_boundary',
                          'tb_dvp_vsync_closes_line','tb_camera_startup_audit','tb_capture_status',
                          'tb_dvp_measure','tb_diag_snapshot','tb_diag_raster')) {
        $taskArgs=@('-c','-lib','./work',$taskTop,'-l',"$taskTop.log",'-do','run -all; quit -f')
        if($taskTop -eq 'tb_dvp_boundary'){$taskArgs+=@('-gWIDTH=1280','-gHEIGHT=720')}
        & "$ModelSimHome/vsim.exe" @taskArgs
        $taskExit=$LASTEXITCODE
        $taskLog=Get-Content "$taskTop.log" -Raw
        if($taskExit -ne 0 -or $taskLog -match '(?i)FAIL|Fatal|TIMEOUT' -or $taskLog -notmatch '_PASS') {
            throw "Simulation failed: $taskTop; see $taskRun"
        }
    }
    Write-Output "CAMERA_VERIFIED_REGRESSION_PASS $taskRun"
} finally {Pop-Location}
