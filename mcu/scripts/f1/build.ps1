param([ValidateSet('Debug','Release')][string]$Configuration='Release')
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1') -Board f1 -Configuration $Configuration
