param([string]$Compiler='C:\MinGW\mingw64\bin\gcc.exe')
$ErrorActionPreference='Stop'
$mcuRoot=Split-Path -Parent $PSScriptRoot
Push-Location $mcuRoot
try {
    New-Item -ItemType Directory -Path 'build/tests' -Force | Out-Null
    function Check([string]$Name,[string[]]$Sources,[string[]]$Includes) {
        $exe="build/tests/$Name.exe"
        & $Compiler '-std=c11' '-O2' '-Wall' '-Wextra' '-Werror' @Includes @Sources '-lm' '-o' $exe
        if ($LASTEXITCODE) {throw "$Name compile failed"}
        & "./$exe"
        if ($LASTEXITCODE) {throw "$Name failed"}
    }
    Check 'wire' @('tests/test_wire.c','firmware/common/wire.c') @('-Ifirmware/common')
    Check 'pose' @('tests/test_pose.c','firmware/common/pose.c') @('-Ifirmware/common')
    Check 'mpu6050' @('tests/test_mpu6050.c','firmware/common/wire.c','firmware/common/pose.c') @('-Itests/mpu_stubs','-Ifirmware/common','-Ifirmware/yuntai/Core/Inc')
    Check 'gateway' @('tests/test_gateway.c','firmware/common/wire.c') @('-Itests/gateway_stubs','-Ifirmware/common','-Ifirmware/longmenjia/Core/Inc')
    Check 'f1_link' @('tests/test_f1_link.c','firmware/common/wire.c','firmware/common/pose.c') @('-Itests/gateway_stubs','-Itests/f1_link_stubs','-Ifirmware/common','-Ifirmware/yuntai/Core/Inc')
    Check 'gimbal' @('tests/f1/test_gimbal.c','firmware/yuntai/Core/Src/gimbal_test.c') @('-Itests/f1/stubs','-Ifirmware/yuntai/Core/Inc')
    Check 'console' @('tests/f1/test_console.c','firmware/yuntai/Core/Src/host_console.c') @('-Itests/f1/stubs','-Ifirmware/yuntai/Core/Inc')
    Check 'servo' @('tests/f1/test_protocol.c','firmware/yuntai/Core/Src/uart_servo_lite.c','firmware/yuntai/Core/Src/ring_buffer.c') @('-Itests/f1/stubs','-Ifirmware/yuntai/Core/Inc')
    Check 'd36a' @('tests/f4/test_d36a_motor.c') @('-Itests/f4/mocks','-Ifirmware/longmenjia/Core/Inc')
    Check 'old_main' @('tests/f4/test_main_validation.c') @('-Itests/f4/mocks','-Ifirmware/longmenjia/Core/Inc')
    & $Compiler '-std=c11' '-Wall' '-Wextra' '-Werror' '-Ifirmware/common' 'tests/generate_vectors.c' 'firmware/common/wire.c' '-o' 'build/tests/generate_vectors.exe'
    if ($LASTEXITCODE) {throw 'Vector generator compilation failed'}
    & './build/tests/generate_vectors.exe' 'tests/vectors.json'
    if ($LASTEXITCODE) {throw 'Vector generation failed'}
    & python '-B' '../host/tests/test_mcu_pose_v2.py'
    if ($LASTEXITCODE) {throw 'Independent host decoder failed'}
} finally { Pop-Location }
