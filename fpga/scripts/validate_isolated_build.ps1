# 用途：对当前 FPGA 输入建立带 SHA-256 的独立快照，再运行既有 PDS 原生全构建。
# 不改 GUI 正在打开的工程、不恢复或删除用户的 bak/日志；本脚本本身不下载 FPGA。
param(
    [Parameter(Mandatory=$true)][string]$RunRoot,
    [Parameter(Mandatory=$true)][string]$LicenseFile,
    [string]$PdsHome = 'E:/PDS_Pangu/PDS_2022.2-SP6.4',
    [string]$Python = 'C:/Users/ROG/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe',
    [switch]$GenerateIps
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'build'))
$runDirectory = [IO.Path]::GetFullPath($RunRoot)
if (!$runDirectory.StartsWith($allowedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'RunRoot must be a dedicated child directory of fpga/build'
}
$snapshotRoot = Join-Path $runDirectory 'workspace/fpga'
if (Test-Path -LiteralPath $snapshotRoot) { throw 'Snapshot already exists; choose a fresh run directory' }
New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null

# 只复制当前实现输入；排除主工程 GUI 状态、旧构建、参考目录及仓库根目录许可证。
$sourceFiles = @()
foreach ($directory in @('rtl','ip','config','constraints','scripts')) {
    $sourceFiles += Get-ChildItem -LiteralPath (Join-Path $sourceRoot $directory) -File -Recurse
}
$sourceFiles += Get-Item -LiteralPath (Join-Path $sourceRoot 'project/pango_video_top/pango_video_top.tcl')
$manifest = @()
foreach ($sourceFile in $sourceFiles) {
    $relative = [IO.Path]::GetRelativePath($sourceRoot, $sourceFile.FullName)
    $destination = Join-Path $snapshotRoot $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
    $copiedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $copiedHash) { throw "Snapshot mismatch: $relative" }
    $manifest += [ordered]@{path=$relative.Replace('\','/'); sha256=$sourceHash.ToLower(); bytes=$sourceFile.Length}
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDirectory 'source_snapshot.json') -Encoding UTF8
Write-Output "SNAPSHOT_VERIFIED files=$($manifest.Count) root=$snapshotRoot"

# 复用已约定的原生 IP/工程生成和八阶段构建；许可证只由既有脚本作用于子进程环境。
& (Join-Path $snapshotRoot 'scripts/build.ps1') -PdsHome $PdsHome -Python $Python -LicenseFile $LicenseFile -GenerateIps:$GenerateIps
if ($LASTEXITCODE -ne 0) { throw 'Isolated native build failed' }

# 构建后重新核对原工作区输入，发现 GUI 或外部同时改动时，不将快照结果冒充最新源码结果。
foreach ($entry in $manifest) {
    $currentHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot $entry.path) -Algorithm SHA256).Hash.ToLower()
    if ($currentHash -ne $entry.sha256) { throw "Source changed during validation: $($entry.path)" }
}
Write-Output 'ISOLATED_BUILD_COMPLETED_SOURCE_UNCHANGED'
