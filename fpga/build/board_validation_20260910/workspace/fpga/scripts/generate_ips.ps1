param(
    [string]$PdsHome = 'E:/PDS_Pangu/PDS_2022.2-SP6.4',
    [string]$Python = 'C:/Users/ROG/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe',
    [string]$LicenseFile = '',
    [string[]]$Only = @()
)
$ErrorActionPreference = 'Stop'
$fpgaRoot = Split-Path $PSScriptRoot -Parent
$buildRoot = Join-Path $fpgaRoot 'build/ip_generation'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$oldLicense = $env:PANGO_LICENSE_FILE
if ($LicenseFile) { $env:PANGO_LICENSE_FILE = (Resolve-Path -LiteralPath $LicenseFile).Path }
try {
    $prepareArgs = @((Join-Path $PSScriptRoot 'prepare_ips.py'), '--pds', $PdsHome)
    if ($Only.Count) { $prepareArgs += '--only'; $prepareArgs += $Only }
    & $Python @prepareArgs
    if ($LASTEXITCODE -ne 0) { throw 'IP parameter preparation failed' }
    $catalog = Get-Content -LiteralPath (Join-Path $fpgaRoot 'config/ip_catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Push-Location $buildRoot
    try {
        foreach ($ip in $catalog.ips) {
            if ($Only.Count -and $ip.name -notin $Only) { continue }
            $idf = Join-Path $fpgaRoot "ip/$($ip.name)/$($ip.name).idf"
            # IP Compiler intentionally refuses to overwrite existing templates.
            # Archive only these two generated files, never vendor source trees.
            $archive = Join-Path $buildRoot ('template_archive/' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
            foreach ($extension in @('v','vhdl')) {
                $template = [IO.Path]::GetFullPath((Join-Path (Split-Path $idf) "$($ip.name)_tmpl.$extension"))
                $ipRoot = [IO.Path]::GetFullPath((Join-Path $fpgaRoot 'ip'))
                if (!$template.StartsWith($ipRoot + [IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe template path' }
                if (Test-Path -LiteralPath $template) {
                    New-Item -ItemType Directory -Path $archive -Force | Out-Null
                    Move-Item -LiteralPath $template -Destination $archive
                }
            }
            $logFile = Join-Path $buildRoot "$($ip.name).log"
            $result = & "$PdsHome/bin/ip_generate.exe" -i $idf -ads -disable-syn 2>&1
            $exitCode = $LASTEXITCODE
            $result | Set-Content -LiteralPath $logFile -Encoding UTF8
            $text = $result -join "`n"
            $summary = ($result | Select-String 'Done:').Line
            Write-Output "$($ip.name): $summary"
            if ($exitCode -ne 0 -or $text -match '(?m)^E:' -or $text -notmatch 'Done: 0 error\(s\), 0 warning\(s\)') {
                throw "Native IP generation failed: $($ip.name); see $logFile"
            }
            [xml]$saved = Get-Content -LiteralPath $idf -Raw
            $sources = @($saved.ip_inst.file_list.source.file)
            if (!$sources.Count) { throw "No generated HDL dependencies: $idf" }
            foreach ($source in $sources) {
                if (!(Test-Path -LiteralPath (Join-Path (Split-Path $idf) $source.pathname))) {
                    throw "Missing generated dependency: $($source.pathname)"
                }
            }
        }
    } finally { Pop-Location }
} finally { $env:PANGO_LICENSE_FILE = $oldLicense }
