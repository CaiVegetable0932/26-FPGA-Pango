param([ValidateSet('yuntai','longmenjia','f1','f4')][string]$Board='yuntai', [ValidateSet('Debug','Release')][string]$Configuration='Release')
$ErrorActionPreference='Stop'
$mcuRoot=Split-Path -Parent $PSScriptRoot
$bundleRoot=Join-Path $env:LOCALAPPDATA 'stm32cube/bundles'
function Tool([string]$bundle,[string]$name) {
    $found=Get-ChildItem -LiteralPath (Join-Path $bundleRoot $bundle) -Directory |
        Sort-Object Name -Descending | ForEach-Object {Join-Path $_.FullName "bin/$name"} |
        Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
    if (!$found) {throw "Missing tool $bundle/$name"}; return $found
}
$cmake=Tool 'cmake' 'cmake.exe'; $gcc=Tool 'gnu-tools-for-stm32' 'arm-none-eabi-gcc.exe'; $ninja=Tool 'ninja' 'ninja.exe'
$env:Path=(Split-Path $gcc)+';'+(Split-Path $ninja)+';'+$env:Path
$boardId=if ($Board -in @('yuntai','f1')) {'f1'} else {'f4'}
$firmwareName=if ($boardId -eq 'f1') {'yuntai'} else {'longmenjia'}
$source=Join-Path $mcuRoot "firmware/$firmwareName"
$build=Join-Path $mcuRoot "build/$boardId/$Configuration"
& $cmake --fresh -S $source -B $build -G Ninja '-DCMAKE_TOOLCHAIN_FILE=cmake/gcc-arm-none-eabi.cmake' "-DCMAKE_BUILD_TYPE=$Configuration"
if ($LASTEXITCODE) {throw 'CMake configure failed'}
& $cmake --build $build
if ($LASTEXITCODE) {throw 'Firmware build failed'}
$name=if ($boardId -eq 'f1') {'yuntai'} else {'FPGA'}
$objcopy=Join-Path (Split-Path $gcc) 'arm-none-eabi-objcopy.exe'
& $objcopy -O ihex (Join-Path $build "$name.elf") (Join-Path $build "$name.hex")
if ($LASTEXITCODE) {throw 'HEX export failed'}
& $objcopy -O binary (Join-Path $build "$name.elf") (Join-Path $build "$name.bin")
if ($LASTEXITCODE) {throw 'BIN export failed'}

# Archive configuration identity alongside images; runtime zero/bias still comes
# from GET_CONFIG and must be recorded by the client for each configuration.
$entries=@()
$inputFiles=@('config/machine_config.json','config/pose_config.h','config/board_interfaces.md','scripts/build.ps1') |
    ForEach-Object {Join-Path $mcuRoot $_}
$inputFiles+=Get-ChildItem -LiteralPath $source,(Join-Path $mcuRoot 'firmware/common') -Recurse -File |
    Where-Object {$_.Extension -in @('.c','.h','.s','.ld','.ioc','.cmake','.json') -or $_.Name -eq 'CMakeLists.txt'} |
    ForEach-Object {$_.FullName}
foreach ($absolute in ($inputFiles | Sort-Object -Unique)) {
    $relative=$absolute.Substring($mcuRoot.Length+1).Replace('\','/')
    $entries+=@{path=$relative;sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$images=@()
foreach ($extension in @('elf','hex','bin')) {
    $absolute=Join-Path $build "$name.$extension"
    $images+=@{path="$name.$extension";bytes=(Get-Item -LiteralPath $absolute).Length;
        sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$compilerVersion=(& $gcc --version | Select-Object -First 1)
$manifest=@{schema_version=1;board=$boardId;firmware_project=$firmwareName;configuration=$Configuration;protocol_profile='MCU_POSE_V2';
    generated_utc=[DateTime]::UtcNow.ToString('o');compiler=$compilerVersion;hardware_verified=$false;
    configuration_and_sources=$entries;images=$images}
$json=$manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $build 'manifest.json'),$json,(New-Object System.Text.UTF8Encoding($false)))
