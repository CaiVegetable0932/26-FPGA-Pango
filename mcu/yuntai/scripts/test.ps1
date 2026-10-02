param([string]$Compiler = 'C:\MinGW\mingw64\bin\gcc.exe')
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
Push-Location $projectDir
try {
    New-Item -ItemType Directory -Path 'tests/build' -Force | Out-Null
    & $Compiler '-std=c11' '-Wall' '-Wextra' '-Werror' '-Itests/stubs' '-ICore/Inc' 'tests/test_gimbal.c' 'Core/Src/gimbal_test.c' '-o' 'tests/build/test_gimbal.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Test compilation failed' }
    & './tests/build/test_gimbal.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Gimbal tests failed' }
    & $Compiler '-std=c11' '-Wall' '-Wextra' '-Werror' '-Itests/stubs' '-ICore/Inc' 'tests/test_console.c' 'Core/Src/host_console.c' '-o' 'tests/build/test_console.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Console test compilation failed' }
    & './tests/build/test_console.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Console tests failed' }
    & $Compiler '-std=c11' '-Wall' '-Wextra' '-Werror' '-Itests/stubs' '-ICore/Inc' 'tests/test_protocol.c' 'Core/Src/uart_servo_lite.c' 'Core/Src/ring_buffer.c' '-o' 'tests/build/test_protocol.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Protocol test compilation failed' }
    & './tests/build/test_protocol.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Protocol tests failed' }
} finally { Pop-Location }
