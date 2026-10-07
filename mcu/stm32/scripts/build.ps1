param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$bundleRoot = $env:CUBE_BUNDLE_PATH
if ([string]::IsNullOrWhiteSpace($bundleRoot) -or !(Test-Path -LiteralPath $bundleRoot)) {
    $bundleRoot = Join-Path $env:LOCALAPPDATA "stm32cube\bundles"
}

if (!(Test-Path -LiteralPath $bundleRoot)) {
    throw "STM32Cube bundles not found at '$bundleRoot'. Set CUBE_BUNDLE_PATH or install STM32Cube tools."
}

function Find-BundleTool([string]$bundleName, [string]$executable) {
    $bundleDirectory = Join-Path $bundleRoot $bundleName
    $candidate = Get-ChildItem -LiteralPath $bundleDirectory -Directory -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { [version](($_.Name -split '\+')[0]) }; Descending = $true } |
        ForEach-Object { Join-Path (Join-Path $_.FullName "bin") $executable } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (!$candidate) {
        throw "Could not find '$executable' in STM32Cube bundle '$bundleDirectory'."
    }

    return (Resolve-Path -LiteralPath $candidate).Path
}

$cmake = Find-BundleTool "cmake" "cmake.exe"
$ninja = Find-BundleTool "ninja" "ninja.exe"
$compiler = Find-BundleTool "gnu-tools-for-stm32" "arm-none-eabi-gcc.exe"
$toolDirectories = @(
    (Split-Path -Parent $cmake),
    (Split-Path -Parent $ninja),
    (Split-Path -Parent $compiler)
)
$env:Path = ($toolDirectories -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:Path

Push-Location $projectRoot
try {
    & $cmake --fresh --preset $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configure failed with exit code $LASTEXITCODE."
    }

    & $cmake --build --preset $Configuration --parallel
    if ($LASTEXITCODE -ne 0) {
        throw "Firmware build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
