param(
    [string]$PdsHome = 'E:/PDS_Pangu/PDS_2022.2-SP6.4',
    [string]$Python = 'C:/Users/ROG/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe',
    [string]$LicenseFile = '',
    [switch]$GenerateIps,
    [ValidateSet('compile','all')][string]$Stage = 'all'
)
$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path $PSScriptRoot -Parent
$buildRoot = Join-Path $fpgaRoot 'build/pango_video_top'
$generationRoot = Join-Path $fpgaRoot 'build/project_generation'
New-Item -ItemType Directory -Path $buildRoot,$generationRoot -Force | Out-Null
$pdsShell = Join-Path $PdsHome 'bin/pds_shell.exe'
$projectFile = Join-Path $fpgaRoot 'project/pango_video_top/pango_video_top.pds'
function Move-PdsConstraintReport {
    $checkPath = [IO.Path]::GetFullPath((Join-Path (Split-Path $projectFile) 'constraint_check'))
    $projectRoot = [IO.Path]::GetFullPath((Split-Path $projectFile))
    if (!$checkPath.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe report directory' }
    if (Test-Path -LiteralPath $checkPath) {
        $unexpected = @(Get-ChildItem -LiteralPath $checkPath -Force | Where-Object { $_.Name -ne 'constraint_check.ccr' -or $_.PSIsContainer })
        if ($unexpected.Count) { throw 'Unexpected files in generated constraint-check directory; preserved for review' }
        $checkArchive = [IO.Path]::GetFullPath((Join-Path $generationRoot ('constraint_check_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))))
        if (!$checkArchive.StartsWith([IO.Path]::GetFullPath($generationRoot) + [IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe report archive directory' }
        Move-Item -LiteralPath $checkPath -Destination $checkArchive
    }
}
$oldLicense = $env:PANGO_LICENSE_FILE
if ($LicenseFile) { $env:PANGO_LICENSE_FILE = (Resolve-Path -LiteralPath $LicenseFile).Path }
try {
    & $Python (Join-Path $PSScriptRoot 'prepare_constraints.py')
    if ($LASTEXITCODE -ne 0) { throw 'Board constraint generation failed' }
    if ($GenerateIps) {
        & (Join-Path $PSScriptRoot 'generate_ips.ps1') -PdsHome $PdsHome -Python $Python
        & $Python (Join-Path $PSScriptRoot 'prepare_constraints.py')
        if ($LASTEXITCODE -ne 0) { throw 'Native DDR constraint adaptation failed' }
    }
    Push-Location $generationRoot
    try {
        $generation = & $pdsShell -file (Join-Path $PSScriptRoot 'create_project.tcl') -work_dir $generationRoot 2>&1
        $nativeExit = $LASTEXITCODE
        $generation | Set-Content -LiteralPath (Join-Path $generationRoot 'generation.log') -Encoding UTF8
        if ($nativeExit -ne 0 -or ($generation -join "`n") -match '(?m)^E:|Check license failed' -or
            ($generation -join "`n") -notmatch 'NATIVE_PROJECT_GENERATED') { throw 'Native project generation failed' }
    } finally { Pop-Location }
    & $Python (Join-Path $PSScriptRoot 'finalize_project.py')
    if ($LASTEXITCODE -ne 0) { throw 'Native project layout finalization failed' }
    Write-Output "PDS-native project generated: $projectFile"
    # tcl2prj creates this report beside the project regardless of -work_dir.
    # Relocate only its known generated directory, within this FPGA workspace.
    Move-PdsConstraintReport
    $started = Get-Date
    [ordered]@{started=$started.ToString('o'); stage=$Stage; status='running'; passed=$false} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildRoot "${Stage}_result.json") -Encoding UTF8
    Push-Location $buildRoot
    try {
        $buildArgs = @('-project', $projectFile, '-work_dir', $buildRoot)
        if ($Stage -eq 'compile') { $buildArgs += @('-run','compile') }
        $output = & $pdsShell @buildArgs 2>&1
        $nativeExit = $LASTEXITCODE
        $output | Set-Content -LiteralPath (Join-Path $buildRoot "${Stage}_console.log") -Encoding UTF8
        $logText = $output -join "`n"
        $errors = @($output | Select-String '(?m)^E:|Check license failed|IPSpecCheck:.*(error|must)')
        & $Python (Join-Path $PSScriptRoot 'finalize_project.py')
        if ($LASTEXITCODE -ne 0) { throw 'Native project layout finalization failed' }
        Move-PdsConstraintReport
        $auditOutput = & $Python (Join-Path $PSScriptRoot 'audit_project.py') --stage $Stage --started $started.ToString('o') 2>&1
        $auditExit = $LASTEXITCODE
        $auditOutput | Set-Content -LiteralPath (Join-Path $buildRoot "${Stage}_audit_console.log") -Encoding UTF8
        $summary = [ordered]@{
            started = $started.ToString('o'); finished = (Get-Date).ToString('o');
            stage = $Stage; native_exit = $nativeExit; error_count = $errors.Count;
            audit_exit = $auditExit;
            project = $projectFile; build = $buildRoot; hardware_tested = $false; programmed = $false
        }
        $summary.passed = $nativeExit -eq 0 -and !$errors.Count -and $auditExit -eq 0
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $buildRoot "${Stage}_result.json") -Encoding UTF8
        $summary | ConvertTo-Json -Depth 6
        if (!$summary.passed) {
            $errors.Line | Select-Object -First 20
            if ($auditExit) { $auditOutput | Select-Object -Last 20 }
            throw "PDS $Stage failed; see ${Stage}_console.log and ${Stage}_audit.json"
        }
    } finally { Pop-Location }
} finally { $env:PANGO_LICENSE_FILE = $oldLicense }
