param(
    [string]$OutDir = '',
    [string]$PdsRoot = ''
)

$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content (Join-Path $fpgaRoot 'config\toolchain.json') -Raw | ConvertFrom-Json
if (-not $PdsRoot) { $PdsRoot = $toolchain.pds_root }
if (-not $OutDir) { $OutDir = Join-Path $fpgaRoot ('build\pango_video_top_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')) }
$OutDir = [IO.Path]::GetFullPath($OutDir)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $fpgaRoot 'build'))
if (-not $OutDir.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar)) {
    throw "OutDir must stay under fpga/build: $OutDir"
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$pds = Join-Path $PdsRoot 'bin\pds_shell.exe'
if (-not (Test-Path -LiteralPath $pds)) { throw "PDS shell not found: $pds" }

$pdsLogPath = Join-Path $OutDir 'pds_shell.log'
$pdsOutput = & $pds -file (Join-Path $PSScriptRoot 'build_video.tcl') -work_dir $OutDir -project_name pango_video_top 2>&1
$pdsOutput | Set-Content -LiteralPath $pdsLogPath -Encoding UTF8
$exitCode = $LASTEXITCODE
$logPath = Join-Path $OutDir 'console.log'
$log = ($pdsOutput -join "`n")
if (Test-Path -LiteralPath $logPath) { $log += "`n" + (Get-Content $logPath -Raw) }
$stages = @('compile','synthesize','dev_map','pnr','report_timing','gen_netlist','gen_bit_stream','report_power')
$stageStatus = [ordered]@{}
foreach ($stage in $stages) { $stageStatus[$stage] = $log.Contains("PANGO_VIDEO_STAGE_PASS $stage") }
$licenseBlocked = $log -match 'Check license failed|Flow-0183|IPCompiler 0009'
$summary = [ordered]@{
    returncode = $exitCode
    output = $OutDir
    project = 'pango_video_top'
    stages = $stageStatus
    license_blocked = $licenseBlocked
    passed = ($exitCode -eq 0 -and -not $licenseBlocked -and ($stageStatus.Values -notcontains $false))
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'build_result.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
if (-not $summary.passed) { exit 1 }
