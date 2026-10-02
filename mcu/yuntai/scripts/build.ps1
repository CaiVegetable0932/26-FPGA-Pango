param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$bundle = Join-Path $env:LOCALAPPDATA 'stm32cube/bundles'
$cmake = Join-Path $bundle 'cmake/4.2.3+st.1/bin/cmake.exe'
$ninja = Join-Path $bundle 'ninja/1.13.2+st.1/bin'
$compiler = Join-Path $bundle 'gnu-tools-for-stm32/14.3.1+st.2/bin'
$env:Path = "$compiler;$ninja;$env:Path"
$reportDir = Join-Path $projectDir 'reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$log = Join-Path $reportDir "build-$Configuration.log"
function Invoke-Logged([string]$Tool, [string[]]$ToolArgs) {
    # Windows PowerShell wraps native stderr in ErrorRecord objects.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Tool @ToolArgs 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log -Append
    $code = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($code -ne 0) { throw "$Tool exited with $code" }
}
Push-Location $projectDir
try {
    # Tee-Object in Windows PowerShell 5 uses UTF-16; keep the same encoding.
    "Configuration: $Configuration" | Set-Content -LiteralPath $log -Encoding Unicode
    Invoke-Logged $cmake @('--preset', $Configuration)
    Invoke-Logged $cmake @('--build', '--preset', $Configuration, '--clean-first')
    $elf = Join-Path $projectDir "build/$Configuration/yuntai.elf"
    & (Join-Path $compiler 'arm-none-eabi-objcopy.exe') '-O' 'ihex' $elf (Join-Path $projectDir "build/$Configuration/yuntai.hex")
    if ($LASTEXITCODE -ne 0) { throw 'HEX export failed' }
    & (Join-Path $compiler 'arm-none-eabi-objcopy.exe') '-O' 'binary' $elf (Join-Path $projectDir "build/$Configuration/yuntai.bin")
    if ($LASTEXITCODE -ne 0) { throw 'BIN export failed' }
} finally {
    Pop-Location
}
