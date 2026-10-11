param([string]$CubeMxRoot = 'C:\cubemx')
$ErrorActionPreference = 'Stop'
$mcuRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$projectDir = Join-Path $mcuRoot 'firmware/yuntai'
$scriptFile = Join-Path $PSScriptRoot 'cubemx-generation.txt'
$commands = @(
    ('config load "' + (Join-Path $projectDir 'yuntai.ioc') + '"'),
    'project generate',
    'exit'
)
[IO.File]::WriteAllLines($scriptFile, $commands, [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $mcuRoot 'reports/f1') -Force | Out-Null
$log = Join-Path $mcuRoot 'reports/f1/cubemx-generation.log'
$ErrorActionPreference = 'Continue'
& (Join-Path $CubeMxRoot 'jre/bin/java.exe') '-Dfile.encoding=UTF-8' '-jar' (Join-Path $CubeMxRoot 'STM32CubeMX.exe') '-q' $scriptFile 2>&1 | Tee-Object -FilePath $log
$ErrorActionPreference = 'Stop'
# CubeMX 6.17 may exit with 1 even after a successful `exit` command.
$content = Get-Content -LiteralPath $log -Raw
if ($content -match '(?m)^KO\r?$' -or $content -notmatch '(?m)^OK\r?$' -or $content -notmatch 'Bye bye') {
    throw "CubeMX generation did not report success (exit $LASTEXITCODE)"
}
